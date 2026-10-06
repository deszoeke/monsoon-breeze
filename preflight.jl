# Preflight: command-line parsing and hardware check, run *before* any package is loaded,
# so that a mistaken request halts before it can touch Julia's compile cache.
# Included by monsoon_convection.jl and setup_precompile.jl.

#####
##### Command-line flags
#####

"""
    parse_flags(args, known)

Parse `--name=value` and bare `--name` (meaning `true`) flags. Hyphens in names are read as
underscores, so `--small-test` and `--small_test` are the same. Unknown flags are an error.
"""
function parse_flags(args, known)
    flags = Dict{String, String}()
    for arg in args
        startswith(arg, "--") || error("Unexpected argument \"$arg\"; flags look like --name or --name=value.")
        name, value = occursin('=', arg) ? split(arg[3:end], '='; limit=2) : (arg[3:end], "true")
        name = replace(name, '-' => '_')
        name in known || error("Unknown flag --$name. Known flags: " * join("--" .* known, ", "))
        flags[name] = value
    end
    return flags
end

function parse_bool(name, value)
    value in ("true", "yes", "1") && return true
    value in ("false", "no", "0") && return false
    error("--$name expects true or false, got \"$value\"")
end

const duration_units = ("d" => 86400.0, "h" => 3600.0, "min" => 60.0, "s" => 1.0)

"""
    parse_duration(name, value)

Parse a duration with a unit suffix, e.g. "96h", "2.5d", "30min", "3600s", into seconds.
"""
function parse_duration(name, value)
    for (unit, seconds) in duration_units
        if endswith(value, unit)
            number = tryparse(Float64, value[1:end-length(unit)])
            number === nothing || return number * seconds
        end
    end
    error("--$name expects a duration with units d, h, min or s (e.g. 96h, 30min), got \"$value\"")
end

#####
##### Hardware check
#####

const valid_architectures = ("cpu", "gpu")

"Cheap test for an NVIDIA GPU that does not load CUDA.jl."
nvidia_gpu_present() = Sys.which("nvidia-smi") !== nothing || ispath("/dev/nvidia0")

"The highest CUDA version the NVIDIA driver supports (\"12.8\"), from nvidia-smi, or nothing."
function driver_cuda_version()
    Sys.which("nvidia-smi") === nothing && return nothing
    output = try read(`nvidia-smi`, String) catch; return nothing end
    m = match(r"CUDA Version:\s*([0-9]+\.[0-9]+)", output)
    return m === nothing ? nothing : m.captures[1]
end

"How to fix CUDA.functional() == false on a node that has an NVIDIA GPU."
function cuda_runtime_fix_message()
    version = something(driver_cuda_version(), "X.Y")
    return """
    The usual cause on HPC: CUDA's runtime package was compiled on a node without a GPU driver
    (e.g. a login node) and recorded "no CUDA runtime". Fix it once by pinning the runtime to
    the driver's CUDA version (nvidia-smi reports $version), then start a new Julia session:
        julia --project -e 'using CUDA; CUDA.set_runtime_version!(v"$version")'
    and check with:  julia --project check_gpu.jl
    (The pin is stored in LocalPreferences.toml, which is per machine and git-ignored.)"""
end

"""
    check_requested_architecture(request)

Return `request` ("cpu" or "gpu") if that hardware is available, otherwise throw an error.
For "gpu", CUDA.jl is loaded only after the cheap device check passes.
"""
function check_requested_architecture(request::AbstractString)
    request = lowercase(strip(request))
    request in valid_architectures ||
        error("--arch must be one of $(valid_architectures), got \"$request\".")

    if request == "gpu"
        nvidia_gpu_present() ||
            error("GPU requested, but no NVIDIA GPU was found (no nvidia-smi, no /dev/nvidia0). " *
                  "Nothing was changed or precompiled.")
        Core.eval(Main, :(using CUDA))
        Base.invokelatest(() -> Main.CUDA.functional()) ||
            error("GPU requested and an NVIDIA device is present, but CUDA.functional() is false. " *
                  "Nothing was changed or precompiled.\n" * cuda_runtime_fix_message())
    end

    return request
end
