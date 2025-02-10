"""
    eventloop(socket, kernel)

Generic event loop for one of the [kernel
sockets](https://jupyter-client.readthedocs.io/en/latest/messaging.html#introduction).
"""
function eventloop(socket, kernel)
    task_local_storage(:IJulia_task, "write task")
    try
        while true
            local msg
            try
                msg = recv_ipython(socket, kernel)
            catch e
                if isa(e, EOFError)
                    # The socket was closed
                    return
                else
                    rethrow()
                end
            end

            try
                send_status("busy", kernel, msg)
                invokelatest(get(handlers, msg.header["msg_type"], unknown_request), socket, kernel, msg)
            catch e
                # Try to keep going if we get an exception, but
                # send the exception traceback to the front-ends.
                # (Ignore SIGINT since this may just be a user-requested
                #  kernel interruption to interrupt long calculations.)
                if !isa(e, InterruptException)
                    content = error_content(e, msg="KERNEL EXCEPTION")
                    map(s -> println(orig_stderr[], s), content["traceback"])
                    send_ipython(kernel.publish[], kernel, msg_pub(kernel.execute_msg, "error", content))
                end
            finally
                flush_all()
                send_status("idle", kernel, msg)
            end
        end
    catch e
        # the Jupyter manager may send us a SIGINT if the user
        # chooses to interrupt the kernel; don't crash on this
        if isa(e, InterruptException)
            eventloop(socket, kernel)
        else
            rethrow()
        end
    end
end

"""
    waitloop(kernel)

Main loop of a kernel. Runs the event loops for the control and shell sockets
(note: in IJulia the shell socket is called `requests`).
"""
function waitloop(kernel, stop_event=Base.Event())
    control_task = @async eventloop(kernel.control[], kernel)
    kernel.requests_task[] = @async eventloop(kernel.requests[], kernel)

    while kernel.inited
        try
            wait(stop_event)
        catch e
            # send interrupts (user SIGINT) to the code-execution task
            if isa(e, InterruptException)
                @async Base.throwto(kernel.requests_task[], e)
            else
                rethrow()
            end
        finally
            close(kernel)
            wait(control_task)
            wait(kernel.requests_task[])
        end
    end
end
