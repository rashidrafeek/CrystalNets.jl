using CrystalNets
using Test, Random
using PeriodicGraphs
using StaticArrays
import Base.Threads

function _finddirs()
    curr = last(splitdir(@__DIR__))
    root = curr == "CrystalNets" ? normpath(@__DIR__) : normpath(@__DIR__, "..")
    return joinpath(root, "test", "cif"), root
end

const known_unstable_nets = ("sxt", "llw-z") # special case for these known unstable nets

@testset "Archive" begin
    @info "Checking that all known topologies are reckognized (this can take a few minutes)."
    tests = Dict{String,Bool}([x=>false for x in values(CrystalNets.CRYSTAL_NETS_ARCHIVE)
                               if x ∉ known_unstable_nets])
    Threads.@threads for (genome, id) in collect(CrystalNets.CRYSTAL_NETS_ARCHIVE)
        if id ∈ known_unstable_nets
            @test_broken reckognize_topology(topological_genome(PeriodicGraph(CrystalNets.REVERSE_CRYSTAL_NETS_ARCHIVE[id]))) == id
            continue
        end
        tests[id] = reckognize_topology(topological_genome(PeriodicGraph(genome))) == id
    end
    for (id, b) in tests
        if !b
            @show "Failed for $id (Archive)"
        end
        @test b
    end
    #=
    failures = String[]
    Threads.@threads for (genome, id) in collect(CrystalNets.CRYSTAL_NETS_ARCHIVE)
        (id == "sxt" || id == "llw-z") && continue # special case for these known unstable nets
        if reckognize_topology(topological_genome(PeriodicGraph(genome))) != id
            push!(failures, id)
        end
    end
    if !isempty(failures)
        @show "Failed: $failures"
    end
    @test isempty(failures)
    =#
end

@testset "Module" begin
    targets = ["pcu", "afy, AFY", "apc, APC", "bam", "bcf", "cdp", "cnd", "ecb", "fiv",
    "ftd", "ftj", "ins", "kgt", "mot", "moz", "muh", "pbz", "qom", "sig",
    "sma", "sod-f", "sod-h", "utj", "utp"]
    tests = Dict{String,Bool}([x=>true for x in targets])
    Threads.@threads for target in targets
        @info "Testing $target"
        graph = PeriodicGraph(CrystalNets.REVERSE_CRYSTAL_NETS_ARCHIVE[target])
        n = PeriodicGraphs.nv(graph)
        for k in 1:50
            r = randperm(n)
            offsets = [SVector{3,Int}([rand(-3:3) for _ in 1:3]) for _ in 1:n]
            graph = swap_axes!(offset_representatives!(graph[r], offsets), randperm(3))
            tests[target] &= reckognize_topology(topological_genome(graph)) == target
        end
    end
    for (id, b) in tests
        if !b
            @show "Failed for $id (Module)"
        end
        @test b
    end

    println(stderr, '\n')
    @info """The following warnings about guessing bonds are expected."""
    println(stderr)
    cifs, crystalnetsdir = _finddirs()
    @test reckognize_topology(topological_genome(CrystalNet(parse_chemfile(joinpath(cifs, "Moganite.cif"))))) == "mog"
end


@testset "Executable" begin
    function capture_out(name)
        result = open(name, "w") do out
            redirect_stdout(CrystalNets.julia_main, out)
        end
        written = readlines(name)
        return result, written
    end

    function __reset_archive!(safeARCHIVE, safeREVERSE)
        empty!(CrystalNets.CRYSTAL_NETS_ARCHIVE)
        empty!(CrystalNets.REVERSE_CRYSTAL_NETS_ARCHIVE)
        merge!(CrystalNets.CRYSTAL_NETS_ARCHIVE, safeARCHIVE)
        merge!(CrystalNets.REVERSE_CRYSTAL_NETS_ARCHIVE, safeREVERSE)
        nothing
    end

    cifs, crystalnetsdir = _finddirs()
    safeARGS = deepcopy(ARGS)
    safeARCHIVE = deepcopy(CrystalNets.CRYSTAL_NETS_ARCHIVE)
    safeREVERSE = deepcopy(CrystalNets.REVERSE_CRYSTAL_NETS_ARCHIVE)
    
    out = tempname()
    empty!(ARGS)

    push!(ARGS, "-g", "3   1 2  0 0 0   1 2  0 0 1   1 2  0 1 0   1 2  1 0 0")
    result, written = capture_out(out)
    @test result == 0
    @test written == ["dia"]

    empty!(ARGS)
    path = joinpath(cifs, "ABW.cif")
    push!(ARGS, path)
    result, written = capture_out(out)
    @test result == 0
    @test written == ["sra, ABW"]

    empty!(ARGS)
    path = joinpath(cifs, "ABW.cif")
    push!(ARGS, "-a", CrystalNets.arc_location*"rcsr.arc", path)
    result, written = capture_out(out)
    @test result == 0
    @test written == ["sra"]
    __reset_archive!(safeARCHIVE, safeREVERSE)

    empty!(ARGS)
    path = joinpath(cifs, "RRO.cif")
    push!(ARGS, path)
    result, written = capture_out(out)
    @test result == 0
    @test written == ["RRO"]

    empty!(ARGS)
    path = joinpath(cifs, "RRO.cif")
    push!(ARGS, "-a", CrystalNets.arc_location*"rcsr.arc", path)
    result, written = capture_out(out)
    @test result == 1
    @test written == ["UNKNOWN"]
    __reset_archive!(safeARCHIVE, safeREVERSE)

    empty!(ARGS)
    path = joinpath(cifs, "HKUST-1.cif")
    push!(ARGS, "-c", "mof", path)
    result, written = capture_out(out)
    @test result == 0
    @test length(written) == 2
    @test last(written) == "tbo"

    empty!(ARGS)
    path = joinpath(cifs, "HKUST-1_sym.cif")
    push!(ARGS, "-c", "mof", path)
    result, written = capture_out(out)
    @test result == 0
    @test length(written) == 2
    @test last(written) == "tbo"

    empty!(ARGS)
    path = joinpath(cifs, "Diamond.cif")
    push!(ARGS, "-c", "atom", path)
    result, written = capture_out(out)
    @test result == 0
    @test written == ["dia"]

    empty!(ARGS)
    push!(ARGS, "--help")
    result, written = capture_out(out)
    @test result == 0
    @test startswith(popfirst!(written), "usage: CrystalNets")
    @test !isempty(popfirst!(written))
    @test occursin("CRYSTAL_FILE", popfirst!(written))
    @test occursin("Form B", popfirst!(written))
    @test occursin("Form C", popfirst!(written))
    @test isempty(popfirst!(written))
    @test isempty(popfirst!(written))
    @test popfirst!(written) == "Automatic reckognition of crystal net topologies."

    empty!(ARGS)
    append!(ARGS, safeARGS)

    if splitdir(@__DIR__) != "test" # if used with include("runtests.jl")
        CrystalNets._reset_archive!()
    end
end
