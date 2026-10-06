# Helpers run before any package is loaded, so that a bad flag or a missing GPU stops a script
# in seconds. Included by monsoon_convection.jl and check_gpu.jl; not run directly.

"""
    parse_flags(args, known)

`--name=value` and bare `--name` (value "true") → Dict. `-` in names reads as `_`.
"""
function parse_flags(args, known)
    flags = Dict{String, String}()
    for arg in args
        startswith(arg, "--") || error("unexpected argument \"$arg\" (flags look like --name or --name=value)")
        name, value = occursin('=', arg) ? split(arg[3:end], '='; limit=2) : (arg[3:end], "true")
        name = replace(name, '-' => '_')
        name in known || error("unknown flag --$name (known: " * join("--" .* known, ", ") * ")")
        flags[name] = value
    end
    return flags
end

"Seconds in a duration like \"96h\", \"2.5d\", \"30min\" or \"3600s\"."
function parse_duration(value)
    for (unit, seconds) in ("d" => 86400.0, "h" => 3600.0, "min" => 60.0, "s" => 1.0)
        number = endswith(value, unit) ? tryparse(Float64, chop(value; tail=length(unit))) : nothing
        number === nothing || return number * seconds
    end
    error("\"$value\" is not a duration with units d, h, min or s (e.g. 96h, 30min)")
end

"""
    require_gpu()

Error unless an NVIDIA GPU is present and CUDA works. CUDA is loaded (into Main) only after
the cheap device check.
"""
function require_gpu()
    Sys.which("nvidia-smi") === nothing && !ispath("/dev/nvidia0") &&
        error("no NVIDIA GPU on this node ($(gethostname()))")

    Core.eval(Main, :(using CUDA))
    Base.invokelatest(() -> Main.CUDA.functional()) && return nothing

    # Usual cause on HPC: CUDA's runtime package was compiled on a node without a driver.
    m = Sys.which("nvidia-smi") === nothing ? nothing : match(r"CUDA Version:\s*([0-9.]+)", read(`nvidia-smi`, String))
    version = m === nothing ? "X.Y" : m.captures[1]
    error("CUDA is not functional. Pin the CUDA runtime to the driver's version, then retry:\n" *
          "    julia --project -e 'using CUDA; CUDA.set_runtime_version!(v\"$version\")'")
end
