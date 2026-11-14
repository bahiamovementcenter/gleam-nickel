//! An Erlang NIF over `nickel-embed`, loaded as the Erlang module `ncl_nif`. It is the
//! in-process backend of the Gleam package `ncl` (bahiamovementcenter/gleam-ncl), and its
//! terms use that package's types, but nothing in it is Gleam-specific.
//!
//! # Threads
//!
//! Nickel's values are reference-counted and not `Send`, while the Erlang VM may run successive
//! NIF calls on different scheduler threads. So each session gets its own OS thread, which owns a
//! [`Program`] and every [`Expr`] taken from it. NIF calls only decode a request, queue it for
//! that thread and return; the thread sends the reply to the caller as a message
//! `{Ref, Reply}`. Schedulers are never blocked, however long an evaluation takes.
//!
//! Expressions cross into Erlang as resources holding a slot number in their session's table.
//! When the VM garbage-collects one, its slot is freed; a session's thread exits once the
//! session and all its expressions are gone.
//!
//! # Safety limits
//!
//! A panic in Nickel is caught and reported as an error. An abort, a stack overflow or running
//! out of memory still stops the whole VM, and a running evaluation can't be interrupted.

use std::{
    cell::RefCell,
    collections::HashMap,
    io::{self, Write},
    panic::{AssertUnwindSafe, catch_unwind},
    path::PathBuf,
    rc::Rc,
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc::{Receiver, Sender, channel},
    },
    thread,
};

use nickel_embed::{
    Diagnostic, Error as NickelError, ErrorFormat, ErrorKind, ExportFormat, Expr, ExprKind,
    FieldPath, MergePriority, Number, PackageMap, Priority, Program, Source, TypecheckMode,
};
use rustler::{
    Atom, BigInt, Encoder, Env, LocalPid, NifResult, NifTaggedEnum, OwnedEnv, Resource,
    ResourceArc, Term,
    env::SavedTerm,
    types::{map::map_new, tuple::make_tuple},
};

mod atoms {
    rustler::atoms! {
        ok, error, none, some, nil, null,
        // Gleam `nickel/value.Value`
        bool, int, float, string, array, record,
        // Gleam `nickel/lazy.View`
        number, enum_tag, enum_variant, other, unevaluated,
        // Gleam `nickel/native.Failure`
        nickel_failure, native_failure,
        // Gleam `nickel/error` types
        parse_error, type_error, contract_violation, import_error, serialization_error,
        package_error,
        diagnostic, label, primary, secondary,
        bug_severity, error_severity, warning_severity, note_severity, help_severity,
        // Gleam `nickel/metadata` types
        field_metadata, default_priority, numeric_priority, force_priority,
    }
}

/// How deep Nickel may recurse before a stack overflow, which would stop the VM. Only touched
/// pages are committed, so this costs address space rather than memory.
const STACK_SIZE: usize = 256 * 1024 * 1024;

// --- Resources -------------------------------------------------------------

/// A session: one thread owning one program and the expressions taken from it.
struct Session {
    id: u64,
    tx: Sender<Message>,
}

#[rustler::resource_impl]
impl Resource for Session {}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.tx.send(Message::SessionDropped);
    }
}

/// An expression, living in its session's thread.
struct ExprHandle {
    session: u64,
    slot: u64,
    tx: Sender<Message>,
}

#[rustler::resource_impl]
impl Resource for ExprHandle {}

impl Drop for ExprHandle {
    fn drop(&mut self) {
        let _ = self.tx.send(Message::Release(self.slot));
    }
}

static NEXT_SESSION: AtomicU64 = AtomicU64::new(1);

// --- Requests --------------------------------------------------------------

/// A source, as Gleam's `native.Input`.
#[derive(NifTaggedEnum)]
enum Input {
    /// Code and the name to give it (empty for the default). Relative imports resolve against
    /// the directory of the name, if it has one.
    Code(String, String),
    File(String),
}

/// An override, as Gleam's `native.Override`.
#[derive(NifTaggedEnum)]
enum Override {
    /// Like the command line's `path=value`: replaces a default value only.
    Assign(Vec<String>, String),
    /// Like `--override path=value`: replaces any value.
    Force(Vec<String>, String),
}

/// A Gleam `Option(String)`.
#[derive(NifTaggedEnum)]
enum OptionalPath {
    None,
    Some(String),
}

/// Everything needed to build a program, as Gleam's `native.Options`.
#[derive(rustler::NifRecord)]
#[tag = "options"]
struct Options {
    inputs: Vec<Input>,
    import_paths: Vec<String>,
    contract_files: Vec<String>,
    /// Contracts given as Nickel code. They are written to temporary files, removed with the
    /// session; imports in them resolve through the import paths.
    contract_code: Vec<String>,
    overrides: Vec<Override>,
    field: Vec<String>,
    /// Collect `std.trace` output for `take_trace`.
    trace: bool,
    /// A package manifest (`Nickel-pkg.ncl`) whose dependencies package imports resolve to,
    /// like `--manifest-path`. Resolving it may fetch packages and write the lock file.
    manifest: OptionalPath,
    /// Where fetched packages are cached, like `--package-cache-dir`; by default the
    /// platform's cache directory.
    package_cache_dir: OptionalPath,
}

#[derive(NifTaggedEnum, Clone, Copy)]
enum EvalMode {
    Deep,
    DeepForExport,
    Shallow,
    RecordSpine,
}

#[derive(NifTaggedEnum, Clone, Copy)]
enum Format {
    Json,
    Yaml,
    Toml,
    Text,
}

impl From<Format> for ExportFormat {
    fn from(f: Format) -> Self {
        match f {
            Format::Json => ExportFormat::Json,
            Format::Yaml => ExportFormat::Yaml,
            Format::Toml => ExportFormat::Toml,
            Format::Text => ExportFormat::Text,
        }
    }
}

/// What a session can be asked to do.
#[derive(NifTaggedEnum)]
enum Request {
    /// Builds the session's program, replacing any earlier one.
    Build(Options),
    /// Evaluates the program and returns an expression.
    Eval(EvalMode),
    /// Evaluates for export and converts the result to a Gleam `Value`. On values with no such
    /// conversion (enum variants, functions), reports Nickel's own export error.
    EvalValue,
    Export(Format),
    /// Typechecks; `true` for strict (enforce) mode.
    Typecheck(bool),
    Parse,
    Query,
    /// Evaluates an expression to weak head normal form.
    ForceExpr(ResourceArc<ExprHandle>),
    /// Describes an expression one level deep, as a Gleam `lazy.View`.
    Inspect(ResourceArc<ExprHandle>),
    /// Evaluates an expression fully and converts it to a Gleam `Value`, leaving out fields
    /// marked `not_exported`.
    ToValue(ResourceArc<ExprHandle>),
    ExportExpr(ResourceArc<ExprHandle>, Format),
    /// Renders an expression as Nickel source.
    Display(ResourceArc<ExprHandle>),
    /// Returns and clears the collected `std.trace` output.
    TakeTrace,
}

enum Message {
    Request {
        // Boxed: build options make requests much larger than the other messages.
        request: Box<Request>,
        reply_to: LocalPid,
        env: OwnedEnv,
        reference: SavedTerm,
    },
    Release(u64),
    SessionDropped,
}

// --- NIFs ------------------------------------------------------------------

/// Starts a session. Its thread starts now and lives until the session and its expressions
/// are garbage-collected.
#[rustler::nif]
fn new_session() -> NifResult<ResourceArc<Session>> {
    let (tx, rx) = channel();
    let id = NEXT_SESSION.fetch_add(1, Ordering::Relaxed);
    let worker_tx = tx.clone();
    thread::Builder::new()
        .name(format!("nickel-session-{id}"))
        .stack_size(STACK_SIZE)
        .spawn(move || Worker::new(id, worker_tx).run(rx))
        .map_err(|e| rustler::Error::Term(Box::new(format!("could not start a thread: {e}"))))?;
    Ok(ResourceArc::new(Session { id, tx }))
}

/// Queues a request; the reply arrives as the message `{Reference, Reply}` sent to `reply_to`.
#[rustler::nif]
fn request<'a>(
    session: ResourceArc<Session>,
    reply_to: LocalPid,
    reference: Term<'a>,
    req: Request,
) -> NifResult<Atom> {
    let expr_session = match &req {
        Request::ForceExpr(e)
        | Request::Inspect(e)
        | Request::ToValue(e)
        | Request::ExportExpr(e, _)
        | Request::Display(e) => Some(e.session),
        _ => None,
    };
    if expr_session.is_some_and(|s| s != session.id) {
        return Err(rustler::Error::Term(Box::new(
            "the expression belongs to another session",
        )));
    }
    let owned = OwnedEnv::new();
    let reference = owned.save(reference);
    session
        .tx
        .send(Message::Request {
            request: Box::new(req),
            reply_to,
            env: owned,
            reference,
        })
        .map_err(|_| rustler::Error::Term(Box::new("the session has stopped")))?;
    Ok(atoms::ok())
}

/// The version of `nickel-lang-core` linked in.
#[rustler::nif]
fn core_version() -> &'static str {
    env!("NICKEL_CORE_VERSION")
}

rustler::init!("ncl_nif");

// --- The session thread ----------------------------------------------------

/// A `Write` that collects `std.trace` output for the session.
#[derive(Clone, Default)]
struct TraceBuffer(Rc<RefCell<Vec<u8>>>);

impl Write for TraceBuffer {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.borrow_mut().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// A reply, built on the session thread and encoded when sent.
enum Reply {
    Ok,
    Expr(Expr),
    Value(Value),
    View(Expr),
    Text(String),
    Metadata(nickel_embed::FieldInfo),
    Nickel(Box<NickelError>),
    Native(String),
}

struct Worker {
    id: u64,
    tx: Sender<Message>,
    program: Option<Program>,
    trace: TraceBuffer,
    exprs: HashMap<u64, Expr>,
    next_slot: u64,
    session_dropped: bool,
    /// Temporary files holding the program's inline contracts.
    temp_files: Vec<PathBuf>,
}

impl Drop for Worker {
    fn drop(&mut self) {
        for path in &self.temp_files {
            let _ = std::fs::remove_file(path);
        }
    }
}

impl Worker {
    fn new(id: u64, tx: Sender<Message>) -> Self {
        Worker {
            id,
            tx,
            program: None,
            trace: TraceBuffer::default(),
            exprs: HashMap::new(),
            next_slot: 0,
            session_dropped: false,
            temp_files: Vec::new(),
        }
    }

    fn run(mut self, rx: Receiver<Message>) {
        // The worker holds a sender itself (to hand to new expressions), so the channel never
        // closes; the thread stops when nothing outside can send to it any more.
        while let Ok(message) = rx.recv() {
            match message {
                Message::Request {
                    request,
                    reply_to,
                    mut env,
                    reference,
                } => {
                    let reply = catch_unwind(AssertUnwindSafe(|| self.handle(*request)))
                        .unwrap_or_else(|panic| {
                            let what = panic
                                .downcast_ref::<String>()
                                .map(String::as_str)
                                .or_else(|| panic.downcast_ref::<&str>().copied())
                                .unwrap_or("unknown cause");
                            Reply::Native(format!("Nickel panicked: {what}"))
                        });
                    // The caller may have exited; then there's no one to tell.
                    let _ = env.send_and_clear(&reply_to, |env| {
                        let reply = catch_unwind(AssertUnwindSafe(|| self.encode(env, reply)))
                            .unwrap_or_else(|_| {
                                native_failure(env, "could not encode the reply".into())
                            });
                        make_tuple(env, &[reference.load(env), reply])
                    });
                }
                Message::Release(slot) => {
                    self.exprs.remove(&slot);
                }
                Message::SessionDropped => self.session_dropped = true,
            }
            if self.session_dropped && self.exprs.is_empty() {
                break;
            }
        }
    }

    fn program(&mut self) -> Result<&mut Program, Reply> {
        self.program
            .as_mut()
            .ok_or_else(|| Reply::Native("the session has no program".into()))
    }

    fn expr(&self, handle: &ExprHandle) -> Result<Expr, Reply> {
        self.exprs
            .get(&handle.slot)
            .cloned()
            .ok_or_else(|| Reply::Native("the expression was released".into()))
    }

    fn handle(&mut self, request: Request) -> Reply {
        self.try_handle(request).unwrap_or_else(|reply| reply)
    }

    fn try_handle(&mut self, request: Request) -> Result<Reply, Reply> {
        let nickel = |e: NickelError| Reply::Nickel(Box::new(e));
        Ok(match request {
            Request::Build(options) => {
                self.program = None;
                self.program = Some(self.build(options).map_err(nickel)?);
                Reply::Ok
            }
            Request::Eval(mode) => {
                let program = self.program()?;
                let expr = match mode {
                    EvalMode::Deep => program.eval_deep(),
                    EvalMode::DeepForExport => program.eval_deep_for_export(),
                    EvalMode::Shallow => program.eval_shallow(),
                    EvalMode::RecordSpine => program.eval_record_spine(),
                };
                Reply::Expr(expr.map_err(nickel)?)
            }
            Request::EvalValue => {
                let program = self.program()?;
                let expr = program.eval_deep_for_export().map_err(nickel)?;
                match to_value(program, &expr, &mut Vec::new()) {
                    Ok(value) => Reply::Value(value),
                    Err(ValueError::Nickel(e)) => nickel(e),
                    // Let Nickel explain why the value can't be exported, as `nickel export`
                    // would.
                    Err(ValueError::Unsupported(why)) => match program.export(ExportFormat::Json) {
                        Err(e) => nickel(e),
                        Ok(_) => Reply::Native(why),
                    },
                }
            }
            Request::Export(format) => {
                Reply::Text(self.program()?.export(format.into()).map_err(nickel)?)
            }
            Request::Typecheck(strict) => {
                let mode = if strict {
                    TypecheckMode::Enforce
                } else {
                    TypecheckMode::Walk
                };
                self.program()?.typecheck(mode).map_err(nickel)?;
                Reply::Ok
            }
            Request::Parse => {
                self.program()?.parse().map_err(nickel)?;
                Reply::Ok
            }
            Request::Query => Reply::Metadata(self.program()?.query().map_err(nickel)?),
            Request::ForceExpr(handle) => {
                let expr = self.expr(&handle)?;
                Reply::Expr(self.program()?.eval_expr_shallow(expr).map_err(nickel)?)
            }
            Request::Inspect(handle) => Reply::View(self.expr(&handle)?),
            Request::ToValue(handle) => {
                let expr = self.expr(&handle)?;
                match to_value(self.program()?, &expr, &mut Vec::new()) {
                    Ok(value) => Reply::Value(value),
                    Err(ValueError::Nickel(e)) => nickel(e),
                    Err(ValueError::Unsupported(why)) => Reply::Native(why),
                }
            }
            Request::ExportExpr(handle, format) => {
                let expr = self.expr(&handle)?;
                let program = self.program()?;
                Reply::Text(program.export_expr(&expr, format.into()).map_err(nickel)?)
            }
            Request::Display(handle) => Reply::Text(self.expr(&handle)?.to_string()),
            Request::TakeTrace => {
                let bytes = std::mem::take(&mut *self.trace.0.borrow_mut());
                Reply::Text(String::from_utf8_lossy(&bytes).into_owned())
            }
        })
    }

    fn build(&mut self, options: Options) -> Result<Program, NickelError> {
        let mut builder = Program::builder()
            .import_paths(options.import_paths)
            .field(options.field.into_iter().collect::<FieldPath>());
        for input in options.inputs {
            builder = builder.source(match input {
                Input::Code(code, name) if name.is_empty() => Source::code(code),
                Input::Code(code, name) => Source::code(code).with_name(name),
                Input::File(path) => Source::file(path),
            });
        }
        for path in options.contract_files {
            builder = builder.apply_contract_file(path);
        }
        for code in options.contract_code {
            let path = std::env::temp_dir().join(format!(
                "ncl-nif-{}-{}-{}.ncl",
                std::process::id(),
                self.id,
                self.temp_files.len()
            ));
            std::fs::write(&path, code)?;
            self.temp_files.push(path.clone());
            builder = builder.apply_contract_file(path);
        }
        for o in options.overrides {
            let (path, code, priority) = match o {
                Override::Assign(path, code) => (path, code, Priority::Neutral),
                Override::Force(path, code) => (path, code, Priority::Force),
            };
            builder = builder.override_with_priority(path.into_iter().collect(), code, priority);
        }
        if options.trace {
            builder = builder.trace(self.trace.clone());
        }
        if let OptionalPath::Some(manifest) = options.manifest {
            let map = match options.package_cache_dir {
                OptionalPath::Some(cache) => PackageMap::from_manifest_with_cache(manifest, cache)?,
                OptionalPath::None => PackageMap::from_manifest(manifest)?,
            };
            builder = builder.package_map(map);
        }
        builder.build()
    }

    // --- Encoding ----------------------------------------------------------

    fn encode<'a>(&mut self, env: Env<'a>, reply: Reply) -> Term<'a> {
        let ok = |t: Term<'a>| make_tuple(env, &[atoms::ok().encode(env), t]);
        match reply {
            Reply::Ok => ok(atoms::nil().encode(env)),
            Reply::Expr(expr) => ok(self.handle_for(expr).encode(env)),
            Reply::Value(value) => ok(value.encode(env)),
            Reply::View(expr) => ok(self.view_term(env, &expr)),
            Reply::Text(text) => ok(text.encode(env)),
            Reply::Metadata(info) => ok(metadata_term(env, &info)),
            Reply::Nickel(e) => error(env, nickel_failure(env, &e)),
            Reply::Native(reason) => error(env, native_failure(env, reason)),
        }
    }

    fn handle_for(&mut self, expr: Expr) -> ResourceArc<ExprHandle> {
        let slot = self.next_slot;
        self.next_slot += 1;
        self.exprs.insert(slot, expr);
        ResourceArc::new(ExprHandle {
            session: self.id,
            slot,
            tx: self.tx.clone(),
        })
    }

    /// One level of an expression, as a Gleam `lazy.View`; nested expressions become handles.
    fn view_term<'a>(&mut self, env: Env<'a>, expr: &Expr) -> Term<'a> {
        let tagged = |tag: Atom, rest: &[Term<'a>]| {
            let mut items = vec![tag.encode(env)];
            items.extend_from_slice(rest);
            make_tuple(env, &items)
        };
        match expr.kind() {
            ExprKind::Null => atoms::null().encode(env),
            ExprKind::Bool(b) => tagged(atoms::bool(), &[b.encode(env)]),
            ExprKind::Number(n) => {
                let (num, den) = rational(&n);
                tagged(atoms::number(), &[num.encode(env), den.encode(env)])
            }
            ExprKind::String(s) => tagged(atoms::string(), &[s.encode(env)]),
            ExprKind::EnumTag(t) => tagged(atoms::enum_tag(), &[t.encode(env)]),
            ExprKind::EnumVariant(t, payload) => {
                let tag = t.encode(env);
                let payload = self.handle_for(payload).encode(env);
                tagged(atoms::enum_variant(), &[tag, payload])
            }
            ExprKind::Record(r) => {
                let fields: Vec<Term<'a>> = r
                    .iter()
                    .map(|(name, value)| {
                        let value = match value {
                            Some(v) => some(env, self.handle_for(v).encode(env)),
                            None => atoms::none().encode(env),
                        };
                        make_tuple(env, &[name.encode(env), value])
                    })
                    .collect();
                tagged(atoms::record(), &[fields.encode(env)])
            }
            ExprKind::Array(a) => {
                let items: Vec<Term<'a>> =
                    a.iter().map(|v| self.handle_for(v).encode(env)).collect();
                tagged(atoms::array(), &[items.encode(env)])
            }
            ExprKind::Unevaluated => atoms::unevaluated().encode(env),
            _ => atoms::other().encode(env),
        }
    }
}

fn some<'a>(env: Env<'a>, t: Term<'a>) -> Term<'a> {
    make_tuple(env, &[atoms::some().encode(env), t])
}

fn option<'a>(env: Env<'a>, value: Option<impl Encoder>) -> Term<'a> {
    match value {
        Some(v) => some(env, v.encode(env)),
        None => atoms::none().encode(env),
    }
}

fn error<'a>(env: Env<'a>, t: Term<'a>) -> Term<'a> {
    make_tuple(env, &[atoms::error().encode(env), t])
}

fn rational(n: &Number<'_>) -> (BigInt, BigInt) {
    let (num, den) = n.as_rational();
    (
        num.parse().expect("Nickel renders integers in decimal"),
        den.parse().expect("Nickel renders integers in decimal"),
    )
}

/// A Gleam `nickel/value.Value`, built on the session thread and encoded when sent.
enum Value {
    Null,
    Bool(bool),
    Int(BigInt),
    Float(f64),
    String(String),
    Array(Vec<Value>),
    Record(Vec<(String, Value)>),
}

impl Encoder for Value {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        let tagged = |tag: Atom, t: Term<'a>| make_tuple(env, &[tag.encode(env), t]);
        match self {
            Value::Null => atoms::null().encode(env),
            Value::Bool(b) => tagged(atoms::bool(), b.encode(env)),
            Value::Int(i) => tagged(atoms::int(), i.encode(env)),
            Value::Float(f) => tagged(atoms::float(), f.encode(env)),
            Value::String(s) => tagged(atoms::string(), s.encode(env)),
            Value::Array(items) => tagged(atoms::array(), items.encode(env)),
            Value::Record(fields) => {
                let mut map = map_new(env);
                for (name, value) in fields {
                    map = map
                        .map_put(name.as_str(), value)
                        .expect("map_new returns a map");
                }
                tagged(atoms::record(), map)
            }
        }
    }
}

enum ValueError {
    Nickel(NickelError),
    /// The value has no `Value` representation; says what and where.
    Unsupported(String),
}

/// Converts an expression to a [`Value`] the way `nickel export` would, evaluating whatever
/// isn't evaluated yet, except that whole numbers stay exact at any size. Enum tags become
/// strings; fields marked `not_exported` or without a value are left out.
fn to_value(
    program: &mut Program,
    expr: &Expr,
    path: &mut Vec<String>,
) -> Result<Value, ValueError> {
    let forced;
    let expr = if matches!(expr.kind(), ExprKind::Unevaluated) {
        forced = program
            .eval_expr_shallow(expr.clone())
            .map_err(ValueError::Nickel)?;
        &forced
    } else {
        expr
    };
    let unsupported = |what: &str, path: &[String]| {
        let at = if path.is_empty() {
            String::new()
        } else {
            format!(" at `{}`", path.join("."))
        };
        ValueError::Unsupported(format!("{what}{at} has no Gleam Value representation"))
    };
    Ok(match expr.kind() {
        ExprKind::Null => Value::Null,
        ExprKind::Bool(b) => Value::Bool(b),
        ExprKind::Number(n) => {
            let (num, den) = rational(&n);
            if den == BigInt::from(1) {
                Value::Int(num)
            } else {
                let f = n.as_f64();
                if !f.is_finite() {
                    return Err(unsupported("a number too large for a float", path));
                }
                Value::Float(f)
            }
        }
        ExprKind::String(s) | ExprKind::EnumTag(s) => Value::String(s.to_owned()),
        ExprKind::Record(r) => {
            let mut fields = Vec::with_capacity(r.len());
            for (name, field) in r.fields() {
                let Some(value) = field.value() else { continue };
                if field.metadata().not_exported() {
                    continue;
                }
                path.push(name.to_owned());
                let value = to_value(program, &value, path)?;
                path.pop();
                fields.push((name.to_owned(), value));
            }
            Value::Record(fields)
        }
        ExprKind::Array(a) => {
            let mut items = Vec::with_capacity(a.len());
            for (i, item) in a.iter().enumerate() {
                path.push(i.to_string());
                items.push(to_value(program, &item, path)?);
                path.pop();
            }
            Value::Array(items)
        }
        ExprKind::EnumVariant(tag, _) => {
            return Err(unsupported(&format!("the enum variant `'{tag}`"), path));
        }
        _ => return Err(unsupported("a function", path)),
    })
}

/// Field metadata as a Gleam `nickel/metadata.FieldMetadata`.
fn metadata_term<'a>(env: Env<'a>, info: &nickel_embed::FieldInfo) -> Term<'a> {
    let m = info.metadata();
    // Sorted, as `nickel query` lists them.
    let mut subfields = info.subfields();
    subfields.sort();
    let priority = match m.merge_priority() {
        Some(MergePriority::Default) => atoms::default_priority().encode(env),
        Some(MergePriority::Force) => atoms::force_priority().encode(env),
        Some(MergePriority::Priority(n)) => {
            let (num, den) = n.as_rational();
            let text = if den == "1" {
                num
            } else {
                format!("{num}/{den}")
            };
            make_tuple(
                env,
                &[atoms::numeric_priority().encode(env), text.encode(env)],
            )
        }
        None => make_tuple(
            env,
            &[atoms::numeric_priority().encode(env), "0".encode(env)],
        ),
    };
    make_tuple(
        env,
        &[
            atoms::field_metadata().encode(env),
            option(env, m.doc()),
            option(env, m.type_annotation()),
            m.contracts().encode(env),
            m.optional().encode(env),
            m.not_exported().encode(env),
            priority,
            subfields.encode(env),
            option(env, info.value().map(|v| elide_closures(&v.to_string()))),
        ],
    )
}

/// Replaces the unevaluated parts that Nickel's pretty-printer shows as `%<closure@0x…>` with
/// `…`, as `nickel query` elides nested values.
fn elide_closures(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("%<closure@") {
        out.push_str(&rest[..start]);
        out.push('…');
        rest = &rest[start..];
        rest = rest.find('>').map_or("", |end| &rest[end + 1..]);
    }
    out.push_str(rest);
    out
}

/// A Nickel error as a Gleam `native.Failure.NickelFailure`: the kind when the error says it
/// for certain (Gleam classifies the rest from the messages), the diagnostics, and the
/// rendered text.
fn nickel_failure<'a>(env: Env<'a>, e: &NickelError) -> Term<'a> {
    let kind = match e.kind() {
        ErrorKind::Parse => Some(atoms::parse_error()),
        ErrorKind::Typecheck => Some(atoms::type_error()),
        ErrorKind::Contract => Some(atoms::contract_violation()),
        ErrorKind::Import => Some(atoms::import_error()),
        ErrorKind::Export => Some(atoms::serialization_error()),
        ErrorKind::Package => Some(atoms::package_error()),
        _ => None,
    };
    let diagnostics: Vec<Term<'a>> = e
        .diagnostics()
        .iter()
        .map(|d| diagnostic_term(env, d))
        .collect();
    make_tuple(
        env,
        &[
            atoms::nickel_failure().encode(env),
            option(env, kind),
            diagnostics.encode(env),
            e.to_string_with(ErrorFormat::Text).encode(env),
        ],
    )
}

fn diagnostic_term<'a>(env: Env<'a>, d: &Diagnostic) -> Term<'a> {
    use nickel_embed::Severity;
    let severity = match d.severity {
        Severity::Bug => atoms::bug_severity(),
        Severity::Warning => atoms::warning_severity(),
        Severity::Note => atoms::note_severity(),
        Severity::Help => atoms::help_severity(),
        _ => atoms::error_severity(),
    };
    let labels: Vec<Term<'a>> = d
        .labels
        .iter()
        .map(|l| {
            let style = if l.primary {
                atoms::primary()
            } else {
                atoms::secondary()
            };
            // Gleam's label has Nickel's file id, which the CLI reports and nickel-embed
            // doesn't expose: -1, as for a CLI label without one.
            make_tuple(
                env,
                &[
                    atoms::label().encode(env),
                    style.encode(env),
                    (-1i64).encode(env),
                    l.range.start.encode(env),
                    l.range.end.encode(env),
                    l.message.encode(env),
                ],
            )
        })
        .collect();
    make_tuple(
        env,
        &[
            atoms::diagnostic().encode(env),
            severity.encode(env),
            option(env, d.code.as_deref()),
            d.message.encode(env),
            labels.encode(env),
            d.notes.encode(env),
        ],
    )
}

fn native_failure(env: Env<'_>, reason: String) -> Term<'_> {
    make_tuple(
        env,
        &[atoms::native_failure().encode(env), reason.encode(env)],
    )
}
