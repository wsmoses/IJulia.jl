using Conda

include("kspec.jl")
if !haskey(ENV, "IJULIA_NODEFAULTKERNEL")
    # Install Jupyter kernel-spec file.
    kernelpath = installkernel("Julia", "--project=@.")
end

# make it easier to get more debugging output by setting JULIA_DEBUG=1
# when building.
IJULIA_DEBUG = true

# remember the user's Jupyter preference, if any; empty == Conda
prefsfile = joinpath(first(DEPOT_PATH), "prefs", "IJulia")
mkpath(dirname(prefsfile))
jupyter = ""

function write_if_changed(filename, contents)
    if !isfile(filename) || read(filename, String) != contents
        write(filename, contents)
    end
end

# Install the deps.jl file:
deps = """
    const IJULIA_DEBUG = $(IJULIA_DEBUG)
    const JUPYTER = $(repr(jupyter))
"""
write_if_changed("deps.jl", deps)
write_if_changed(prefsfile, jupyter)
