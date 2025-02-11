"""
**IJulia** is a [Julia-language](http://julialang.org/) backend
combined with the [Jupyter](http://jupyter.org/) interactive
environment (also used by [IPython](http://ipython.org/)).  This
combination allows you to interact with the Julia language using
Jupyter/IPython's powerful [graphical
notebook](http://ipython.org/notebook.html), which combines code,
formatted text, math, and multimedia in a single document.

The `IJulia` module is used in three ways

* Typing `using IJulia; notebook()` will launch the Jupyter notebook
  interface in your web browser.  This is an alternative to launching
  `jupyter notebook` directly from your operating-system command line.
* In a running notebook, the `IJulia` module is loaded and `IJulia.somefunctions`
  can be used to interact with the running IJulia kernel:

  - `IJulia.load(filename)` and `IJulia.load_string(s)` load the contents
    of a file or a string, respectively, into a notebook cell.
  - `IJulia.clear_output()` to clear the output from the notebook cell,
    useful for simple animations.
  - `IJulia.clear_history()` to clear the history variables `In` and `Out`.
  - `push_X_hook(f)` and `pop_X_hook(f)`, where `X` is either
    `preexecute`, `postexecute`, or `posterror`.  This allows you to
    insert a "hook" function into a list of functions to execute
    when notebook cells are evaluated.
  - `IJulia.set_verbose()` enables verbose output about what IJulia
    is doing internally; this is mainly used for debugging.

* It is used internally by the IJulia kernel when talking
  to the Jupyter server.
"""
module IJulia
export notebook, jupyterlab, installkernel

using ZMQ, JSON, SoftGlobalScope
import Base.invokelatest
import Dates
using Dates: now, format, UTC, ISODateTimeFormat
import Random
using Base64: Base64EncodePipe
import REPL

# InteractiveUtils is not used inside IJulia, but loaded in src/kernel.jl
# and this import makes it possible to load InteractiveUtils from the IJulia namespace
import InteractiveUtils

const IJULIA_DEBUG = true

import JSON

#######################################################################
# Install Jupyter kernel-spec files.

copy_config(src, dest) = cp(src, joinpath(dest, basename(src)), force=true)

# return the user kernelspec directory, according to
#     https://jupyter-client.readthedocs.io/en/latest/kernels.html#kernelspecs
@static if Sys.iswindows()
    function appdata() # return %APPDATA%
        path = zeros(UInt16, 300)
        CSIDL_APPDATA = 0x001a
        result = ccall((:SHGetFolderPathW,:shell32), stdcall, Cint,
            (Ptr{Cvoid},Cint,Ptr{Cvoid},Cint,Ptr{UInt16}),C_NULL,CSIDL_APPDATA,C_NULL,0,path)
        return result == 0 ? transcode(String, resize!(path, findfirst(iszero, path)-1)) : get(ENV, "APPDATA", "")
    end
    function default_jupyter_data_dir()
        APPDATA = appdata()
        return !isempty(APPDATA) ? joinpath(APPDATA, "jupyter") : joinpath(get(ENV, "JUPYTER_CONFIG_DIR", joinpath(homedir(), ".jupyter")), "data")
    end
elseif Sys.isapple()
    default_jupyter_data_dir() = joinpath(homedir(), "Library/Jupyter")
else
    function default_jupyter_data_dir()
        xdg_data_home = get(ENV, "XDG_DATA_HOME", "")
        data_home = !isempty(xdg_data_home) ? xdg_data_home : joinpath(homedir(), ".local", "share")
        joinpath(data_home, "jupyter")
    end
end

function jupyter_data_dir()
    env_data_dir = get(ENV, "JUPYTER_DATA_DIR", "")
    !isempty(env_data_dir) ? env_data_dir : default_jupyter_data_dir()
end

kerneldir() = joinpath(jupyter_data_dir(), "kernels")

# Since kernelspecs show up in URLs and other places, a kernelspec is required
# to have a simple name, only containing ASCII letters, ASCII numbers, and the
# simple separators: - hyphen, . period, _ underscore. According to
#       https://jupyter-client.readthedocs.io/en/stable/kernels.html
function kernelspec_name(name::AbstractString)
    name = replace(lowercase(name), " "=>"-")
    replace(name, r"[^0-9a-z_\-\.]" => s"_")
end

if Sys.iswindows()
    exe(s::AbstractString) = endswith(s, ".exe") ? s : "$s.exe"
    exe(s::AbstractString, e::AbstractString) =
        string(endswith(s, ".exe") ? s[1:end-4] : s, e, ".exe")
else
    exe(s::AbstractString) = s
    exe(s::AbstractString, e::AbstractString) = s * e
end

function display_name(name::AbstractString)
    debugdesc = ccall(:jl_is_debugbuild,Cint,())==1 ? "-debug" : ""
    return name * " " * Base.VERSION_STRING * debugdesc
end

"""
    installkernel(name::AbstractString, options::AbstractString...;
                  julia::Cmd,
                  specname::AbstractString,
                  displayname::AbstractString,
                  env=Dict())

Install a new Julia kernel, where the given `options` are passed to the `julia`
executable, the user-visible kernel name is given by `name` followed by the
Julia version, and the `env` dictionary is added to the environment.

The new kernel name is returned by `installkernel`.  For example:
```julia
kernelpath = installkernel("Julia O3", "-O3", env=Dict("FOO"=>"yes"))
```
creates a new Julia kernel in which `julia` is launched with the `-O3`
optimization flag and `FOO=yes` is included in the environment variables.

The `displayname` argument can be used to customize the name displayed in the
Jupyter kernel list.

The returned `kernelpath` is the path of the installed kernel directory,
something like `/...somepath.../kernels/julia-o3-1.6` (in Julia 1.6).  The
`specname` argument can be passed to alter the name of this directory (which
defaults to `name` with spaces replaced by hyphens, and special characters
other than `-` hyphen, `.` period and `_` underscore replaced by `_` underscores).

You can uninstall the kernel by calling `rm(kernelpath, recursive=true)`.

You can specify a custom command to execute Julia via keyword argument
`julia`. For example, you may want specify that the Julia kernel is running
in a Docker container (but Jupyter will run outside of it), by calling
`installkernel` from within such a container instance like this (or similar):

```julia
installkernel(
    "Julia via Docker",
    julia = `docker run --rm --net=host
        --volume=/home/USERNAME/.local/share/jupyter:/home/USERNAME/.local/share/jupyter
        some-container /opt/julia-1.x/bin/julia`
)
```
"""
function installkernel(name::AbstractString, julia_options::AbstractString...;
                   julia::Cmd = `$(joinpath(Sys.BINDIR,exe("julia")))`,
                   specname::AbstractString = kernelspec_name(name),
                   displayname::AbstractString = display_name(name),
                   env::Dict{<:AbstractString}=Dict{String,Any}())
    # Is IJulia being built from a debug build? If so, add "debug" to the description.
    debugdesc = ccall(:jl_is_debugbuild,Cint,())==1 ? "-debug" : ""

    # path of the Jupyter kernelspec directory to install
    juliakspec = joinpath(kerneldir(), "$specname-$(VERSION.major).$(VERSION.minor)$debugdesc")
    @info("Installing $name kernelspec in $juliakspec")
    rm(juliakspec, force=true, recursive=true)
    try
        kernelcmd_array = String[julia.exec..., "-i", "--color=yes"]
        append!(kernelcmd_array, julia_options)
        ijulia_dir = get(ENV, "IJULIA_DIR", dirname(@__DIR__)) # support non-Pkg IJulia installs
        append!(kernelcmd_array, [joinpath(ijulia_dir,"src","kernel.jl"), "{connection_file}"])

        ks = Dict(
            "argv" => kernelcmd_array,
            "display_name" => displayname,
            "language" => "julia",
            "env" => env,
            # Jupyter's signal interrupt mode is not supported on Windows
            "interrupt_mode" => Sys.iswindows() ? "message" : "signal",
        )

        mkpath(juliakspec)

        open(joinpath(juliakspec, "kernel.json"), "w") do f
            # indent by 2 for readability of file
            write(f, JSON.json(ks, 2))
        end

        copy_config(joinpath(ijulia_dir,"deps","logo-32x32.png"), juliakspec)
        copy_config(joinpath(ijulia_dir,"deps","logo-64x64.png"), juliakspec)
        copy_config(joinpath(ijulia_dir,"deps","logo-svg.svg"), juliakspec)

        return juliakspec
    catch
        rm(juliakspec, force=true, recursive=true)
        rethrow()
    end
end

#######################################################################
# Debugging IJulia

# in the Jupyter front-end, enable verbose output via IJulia.set_verbose()
verbose = IJULIA_DEBUG
"""
    set_verbose(v=true)

This function enables (or disables, for `set_verbose(false)`) verbose
output from the IJulia kernel, when called within a running notebook.
This consists of log messages printed to the terminal window where
`jupyter` was launched, displaying information about every message sent
or received by the kernel.   Used for debugging IJulia.
"""
function set_verbose(v::Bool=true)
    global verbose = v
end

"""
`inited` is a global variable that is set to `true` if the IJulia
kernel is running, i.e. in a running IJulia notebook.  To test
whether you are in an IJulia notebook, therefore, you can check
`isdefined(Main, :IJulia) && IJulia.inited`.
"""
inited = false

const _capture_docstring = """
The IJulia kernel captures all [stdout and stderr](https://en.wikipedia.org/wiki/Standard_streams)
output and redirects it to the notebook.   When debugging IJulia problems,
however, it can be more convenient to *not* capture stdout and stderr output
(since the notebook may not be functioning). This can be done by editing
`IJulia.jl` to set `capture_stderr` and/or `capture_stdout` to `false`.
"""

@doc _capture_docstring
const capture_stdout = true

# set this to false for debugging, to disable stderr redirection
@doc _capture_docstring
const capture_stderr = !IJULIA_DEBUG

set_current_module(m::Module) = current_module[] = m
const current_module = Ref{Module}(Main)

#######################################################################
#######################################################################

"""
    load_string(s, replace=false)

Load the string `s` into a new input code cell in the running IJulia notebook,
somewhat analogous to the `%load` magics in IPython. If the optional argument
`replace` is `true`, then `s` replaces the *current* cell rather than creating
a new cell.
"""
function load_string(s::AbstractString, replace::Bool=false)
    push!(execute_payloads, Dict(
        "source"=>"set_next_input",
        "text"=>s,
        "replace"=>replace
    ))
    return nothing
end

"""
    load(filename, replace=false)

Load the file given by `filename` into a new input code cell in the running
IJulia notebook, analogous to the `%load` magics in IPython.
If the optional argument `replace` is `true`, then the file contents
replace the *current* cell rather than creating a new cell.
"""
load(filename::AbstractString, replace::Bool=false) =
    load_string(read(filename, String), replace)

#######################################################################
# History: global In/Out and other exported history variables
"""
`In` is a global dictionary of input strings, where `In[n]`
returns the string for input cell `n` of the notebook (as it was
when it was *last evaluated*).
"""
const In = Dict{Int,String}()
"""
`Out` is a global dictionary of output values, where `Out[n]`
returns the output from the last evaluation of cell `n` in the
notebook.
"""
const Out = Dict{Int,Any}()
"""
`ans` is a global variable giving the value returned by the last
notebook cell evaluated.
"""
ans = nothing

# execution counter
"""
`IJulia.n` is the (integer) index of the last-evaluated notebook cell.
"""
n = 0

#######################################################################
# methods to clear history or any subset thereof

function clear_history(indices)
    for n in indices
        delete!(In, n)
        if haskey(Out, n)
            delete!(Out, n)
        end
    end
end

# since a range could be huge, intersect it with 1:n first
clear_history(r::AbstractRange{<:Integer}) =
    invoke(clear_history, Tuple{Any}, intersect(r, 1:n))

function clear_history()
    empty!(In)
    empty!(Out)
    global ans = nothing
end

"""
    clear_history([indices])

The `clear_history()` function clears all of the input and output
history stored in the running IJulia notebook.  This is sometimes
useful because all cell outputs are remember in the `Out` global variable,
which prevents them from being freed, so potentially this could
waste a lot of memory in a notebook with many large outputs.

The optional `indices` argument is a collection of indices indicating
a subset of cell inputs/outputs to clear.
"""
clear_history

#######################################################################
# methods to print history or any subset thereof
function history(io::IO, indices::AbstractVector{<:Integer})
    for n in intersect(indices, 1:IJulia.n)
      if haskey(In, n)
        print(io, In[n])
      end
    end
end

history(io::IO, x::Union{Integer,AbstractVector{<:Integer}}...) = history(io, vcat(x...))
history(x...) = history(stdout, x...)
history(io::IO, x...) = throw(MethodError(history, (io, x...,)))
history() = history(1:n)
"""
    history([io], [indices...])

The `history()` function prints all of the input history stored in
the running IJulia notebook in a format convenient for copying.

The optional `indices` argument is one or more indices or collections
of indices indicating a subset input cells to print.

The optional `io` argument is for specifying an output stream. The default
is `stdout`.
"""
history

#######################################################################
# Similar to the ipython kernel, we provide a mechanism by
# which modules can register thunk functions to be called after
# executing an input cell, e.g. to "close" the current plot in Pylab.
# Modules should only use these if isdefined(Main, IJulia) is true.

const postexecute_hooks = Function[]
"""
    push_postexecute_hook(f::Function)

Push a function `f()` onto the end of a list of functions to
execute after executing any notebook cell.
"""
push_postexecute_hook(f::Function) = push!(postexecute_hooks, f)
"""
    pop_postexecute_hook(f::Function)

Remove a function `f()` from the list of functions to
execute after executing any notebook cell.
"""
pop_postexecute_hook(f::Function) =
    splice!(postexecute_hooks, findlast(isequal(f), postexecute_hooks))

const preexecute_hooks = Function[]
"""
    push_preexecute_hook(f::Function)

Push a function `f()` onto the end of a list of functions to
execute before executing any notebook cell.
"""
push_preexecute_hook(f::Function) = push!(preexecute_hooks, f)
"""
    pop_preexecute_hook(f::Function)

Remove a function `f()` from the list of functions to
execute before executing any notebook cell.
"""
pop_preexecute_hook(f::Function) =
    splice!(preexecute_hooks, findlast(isequal(f), preexecute_hooks))

# similar, but called after an error (e.g. to reset plotting state)
const posterror_hooks = Function[]
"""
    pop_posterror_hook(f::Function)

Remove a function `f()` from the list of functions to
execute after an error occurs when a notebook cell is evaluated.
"""
push_posterror_hook(f::Function) = push!(posterror_hooks, f)
"""
    pop_posterror_hook(f::Function)

Remove a function `f()` from the list of functions to
execute after an error occurs when a notebook cell is evaluated.
"""
pop_posterror_hook(f::Function) =
    splice!(posterror_hooks, findlast(isequal(f), posterror_hooks))

#######################################################################

# The user can call IJulia.clear_output() to clear visible output from the
# front end, useful for simple animations.  Using wait=true clears the
# output only when new output is available, for minimal flickering.
"""
    clear_output(wait=false)

Call `clear_output()` to clear visible output from the current notebook
cell.  Using `wait=true` clears the output only when new output is
available, which reduces flickering and is useful for simple animations.
"""
function clear_output(wait=false)
    # flush pending stdio
    flush_all()
    empty!(displayqueue) # discard pending display requests
    send_ipython(publish[], msg_pub(execute_msg::Msg, "clear_output",
                                    Dict("wait" => wait)))
    stdio_bytes[] = 0 # reset output throttling
end


"""
    set_max_stdio(max_output::Integer)

Sets the maximum number of bytes, `max_output`, that can be written to stdout and
stderr before getting truncated. A large value here allows a lot of output to be
displayed in the notebook, potentially bogging down the browser.
"""
function set_max_stdio(max_output::Integer)
    max_output_per_request[] = max_output
end


#######################################################################

include("init.jl")
include("hmac.jl")
include("eventloop.jl")
include("stdio.jl")
include("msg.jl")
include("display.jl")
include("magics.jl")
include("comm_manager.jl")
include("execute_request.jl")
include("handlers.jl")
include("heartbeat.jl")
include("inline.jl")

end # IJulia
