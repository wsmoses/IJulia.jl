ENV["JULIA_CONDAPKG_ENV"] = "@ijulia-tests"
# ENV["JULIA_PYTHONCALL_EXE"] = "/home/james/.julia/conda_environments/ijulia-tests/bin/python"
# ENV["JULIA_CONDAPKG_BACKEND"] = "Null"

using Test
import Sockets
import Sockets: listenany

import PythonCall
import PythonCall: Py, pyimport, pyconvert, pytype, pystr

# A little bit of hackery to fix the version number sent by the client. See:
# https://github.com/jupyter/jupyter_client/pull/1054
jupyter_client_lib = pyimport("jupyter_client")
jupyter_client_lib.session.protocol_version = "5.4"

const BlockingKernelClient = jupyter_client_lib.BlockingKernelClient

import IJulia: Kernel


function getports(port_hint, n)
    ports = Int[]

    for i in 1:n
        port, server = listenany(Sockets.localhost, port_hint)
        close(server)
        push!(ports, port)
        port_hint = port + 1
    end

    return ports
end

function create_profile(port_hint=8080)
    ports = getports(port_hint, 5)

    Dict(
        "transport" => "tcp",
        "ip" => "127.0.0.1",
        "control_port" => ports[1],
        "shell_port" => ports[2],
        "stdin_port" => ports[3],
        "hb_port" => ports[4],
        "iopub_port" => ports[5],
        "signature_scheme" => "hmac-sha256",
        "key" => "a0436f6c-1916-498b-8eb9-e81ab9368e84"
    )
end

function test_py_get!(get_func, result)
    try
        result[] = get_func(timeout=0)
        return true
    catch ex
        exception_type = pyconvert(String, ex.t.__name__)
        if exception_type != "Empty"
            rethrow()
        end

        return false
    end
end

function recursive_pyconvert(x)
    x_type = pyconvert(String, pytype(x).__name__)

    if x_type == "dict"
        x = pyconvert(Dict{String, Any}, x)
        for key in copy(keys(x))
            if x[key] isa Py
                x[key] = recursive_pyconvert(x[key])
            elseif x[key] isa PythonCall.PyDict
                x[key] = recursive_pyconvert(x[key].py)
            end
        end
    elseif x_type == "str"
        x = pyconvert(String, x)
    end

    return x
end

# Calling methods directly with `reply=true` on the BlockingKernelClient will
# cause a deadlock because the client will block the whole thread while polling
# the socket, which means that the thread will never enter a GC safepoint so any
# other code that happens to allocate will get blocked. Instead, we send
# requests by themselves and then poll the appropriate socket with `timeout=0`
# so that the Python code will never block and we never get into a deadlock.
function make_request(request_func, get_func, args...; kwargs...)
    request_func(args...; kwargs..., reply=false)

    result = Ref{Py}()
    if timedwait(() -> test_py_get!(get_func, result), 10) == :timed_out
        error("Jupyter channel get timed out")
    end

    return recursive_pyconvert(result[])
end

kernel_info(client) = make_request(client.kernel_info, client.get_shell_msg)
comm_info(client) = make_request(client.comm_info, client.get_shell_msg)
history(client; kwargs...) = make_request(client.history, client.get_shell_msg; kwargs...)
shutdown(client; kwargs...) = make_request(client.shutdown, client.get_control_msg; kwargs...)

get_iopub_msg(client) = make_request(Returns(nothing), client.get_iopub_msg)

function execute(client, code)
    make_request(client.execute, client.get_shell_msg; code)

    msg = get_iopub_msg(client)
    while !haskey(msg["content"], "data")
        msg = get_iopub_msg(client)
    end

    return msg
end

function jupyter_client(f, profile)
    client = BlockingKernelClient()
    client.load_connection_info(profile)
    client.start_channels()

    try
        f(client)
    finally
        client.stop_channels()
    end
end

@testset "Kernel" begin
    let kernel = Kernel()
        # Test setting special fields that should be mirrored to global variables
        for field in (:n, :ans, :inited, :verbose)
            # Save the old value so we can restore them afterwards
            old_value = getproperty(kernel, field)

            test_value = field ∈ (:inited, :verbose) ? true : 10
            setproperty!(kernel, field, test_value)
            @test getproperty(IJulia, field) == test_value
            @test getproperty(kernel, field) == test_value

            setproperty!(kernel, field, old_value)
        end
    end

    profile = create_profile()
    shutdown_called = false
    Kernel(profile; capture_stdout=false, capture_stderr=false, shutdown=() -> shutdown_called = true) do kernel
        stop_event = Base.Event()
        t = Threads.@spawn IJulia.waitloop(kernel, stop_event)

        jupyter_client(profile) do client
            @test kernel_info(client)["content"]["status"] == "ok"
            @test comm_info(client)["content"]["status"] == "ok"
            @test execute(client, "42")["content"] == Dict("data" => Dict("text/plain" => "42"),
                                                           "metadata" => Dict(),
                                                           "execution_count" => 1)
            @test history(client)["content"]["status"] == "ok"
            @test shutdown(client)["content"]["status"] == "ok"
            @test timedwait(() -> shutdown_called, 10) == :ok
        end

        notify(stop_event)
        wait(t)
    end

    stdout_pipe = Pipe()
    stderr_pipe = Pipe()
    Base.link_pipe!(stdout_pipe)
    Base.link_pipe!(stderr_pipe)
    stdout_str = ""
    stderr_str = ""
    test_proc = nothing

    Kernel(profile; shutdown=Returns(nothing)) do kernel
        test_file = joinpath(@__DIR__, "kernel_test.py")

        mktemp() do connection_file, io
            # Write the connection file
            profile_kwargs = Dict([Symbol(key) => value for (key, value) in profile])
            profile_kwargs[:key] = pystr(profile_kwargs[:key]).encode()
            jupyter_client_lib.connect.write_connection_file(; fname=connection_file, profile_kwargs...)

            stop_event = Base.Event()
            t = Threads.@spawn IJulia.waitloop(kernel, stop_event)
            IJulia.watch_stdio(kernel)
            pushdisplay(IJulia.InlineDisplay())
            try
                # Run jupyter_kernel_test
                cmd = ignorestatus(`$(PythonCall.C.python_executable_path()) $(test_file)`)
                cmd = addenv(cmd, "IJULIA_TESTS_CONNECTION_FILE" => connection_file)
                cmd = pipeline(cmd; stdout=stdout_pipe, stderr=stderr_pipe)
                test_proc = run(cmd)
            finally
                popdisplay()
                close(stdout_pipe.in)
                close(stderr_pipe.in)
                stdout_str = read(stdout_pipe, String)
                stderr_str = read(stderr_pipe, String)
                close(stdout_pipe)
                close(stderr_pipe)

                notify(stop_event)
                wait(t)
            end
        end
    end

    if !isempty(stdout_str)
        @info "jupyter_kernel_test stdout:"
        println(stdout_str)
    end
    if !isempty(stderr_str)
        @info "jupyter_kernel_test stderr:"
        println(stderr_str)
    end
    if !success(test_proc)
        error("jupyter_kernel_test failed")
    end
end
