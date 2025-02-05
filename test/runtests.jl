import Aqua
import IJulia

const TEST_FILES = [
    "install.jl", "comm.jl", "msg.jl", "execute_request.jl", "stdio.jl",
    "inline.jl"
]

for file in TEST_FILES
    println(file)
    include(file)
end

# MicroMamba (and thus CondaPkg and PythonCall) are not supported on 32bit
if Sys.WORD_SIZE != 32
    include("waitloop.jl")
else
    @warn "Skipping the waitloop tests on 32bit"
end

Aqua.test_all(IJulia)
