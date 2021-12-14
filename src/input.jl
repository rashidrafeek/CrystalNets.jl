## Functions to handle input files.

import Chemfiles
using Statistics: std

include("clustering.jl")
include("guessbonds.jl")


"""
    parse_cif(file_path)

Parse a CIF file and return a dictionary where each identifier (without the
starting '_' character) is linked to its value.
Values are either a string or a vector of string (if defined in a loop).
"""
function parse_cif(file)
    all_data = Dict{String, Union{String, Vector{String}}}()
    inloop = false
    loopisspecified = false
    loopspec = String[]
    loop_n = 0

    l = read(file, String)
    i, j, x = nextword(l, 0)
    while i != 0

        if inloop
            if !loopisspecified
                if l[i] != '_' # This indicates the start of the values
                    loop_n = length(loopspec)
                    loopisspecified = true
                else # The identifier is part of the loop specification
                    push!(loopspec, l[i+1:j])
                    all_data[l[i+1:j]] = String[]
                    i, j, x = nextword(l, x); continue
                end
            end

            # From this point, the loop has been specified
            @assert loopisspecified
            if l[i] != '_' && l[i:j] != "loop_"
                for k in 1:loop_n
                    push!(all_data[loopspec[k]], l[i:j])
                    i, j, x = nextword(l, x)
                end
                continue
            end
            if l[i:j] == "loop_"
                loopisspecified = false
                loopspec = String[]
                i, j, x = nextword(l, x); continue
            end

            # This point can only be reached if we just quitted a loop
            inloop = false
        end

        @assert !inloop
        if l[i] == '_' # Simple identifier definition
            next_i, next_j, next_x = nextword(l, x)
            @assert next_i != 0
            all_data[l[i+1:j]] = l[next_i:next_j]
            x = next_x
        else
            if l[i:j] == "loop_"
                inloop = true
                loopisspecified = false
                loopspec = String[]
            elseif j-i > 4 && l[i:i+4] == "data_"
                @assert !haskey(all_data, "data")
                all_data["data"] = l[i+5:j]
            else
                k::Int = findprev(isequal('\n'), l, i)
                n::Int = count("\n", l[1:k])
                error("Unkown word \"$(l[i:j])\" at line $(n+1), position $(i-k):$(j-k)")
            end
        end

        i, j, x = nextword(l, x)
    end

    return all_data
end

function parsestrip(T, s)
    s = s[end] == ')' ? s[1:prevind(s, findlast('(', s))] : s
    return parse(T, s)
end
parsestrip(s) = parsestrip(BigFloat, s)


"""
    CIF(file_path::AbstractString)

Make a CIF object out of the parsed file.
"""
CIF(file::AbstractString) = CIF(parse_cif(file))
function CIF(parsed::Dict{String, Union{Vector{String},String}})
    natoms = length(parsed["atom_site_label"])
    equivalentpositions = haskey(parsed, "symmetry_equiv_pos_as_xyz") ?
        pop!(parsed, "symmetry_equiv_pos_as_xyz")::Vector{String} : 
        haskey(parsed, "space_group_symop_operation_xyz") ?
            pop!(parsed, "space_group_symop_operation_xyz")::Vector{String} : String[]
    refid = find_refid(equivalentpositions)
    hall = find_hall_number(
            haskey(parsed, "space_group_name_Hall") ?
                pop!(parsed, "space_group_name_Hall")::String :
                haskey(parsed, "symmetry_space_group_name_Hall") ?
                    pop!(parsed, "symmetry_space_group_name_Hall")::String : "",
            haskey(parsed, "space_group_name_H-M_alt") ?
                pop!(parsed, "space_group_name_H-M_alt")::String :
                haskey(parsed, "symmetry_space_group_name_H-M") ?
                    pop!(parsed, "symmetry_space_group_name_H-M")::String : "",
            haskey(parsed, "symmetry_Int_Tables_number") ?
                parse(Int, pop!(parsed, "symmetry_Int_Tables_number")::String) :
                haskey(parsed, "space_group.IT_number") ? 
                    parse(Int, pop!(parsed, "space_group.IT_number")::String) : 0)
    cell = Cell(hall, (parsestrip(pop!(parsed, "cell_length_a")::String),
                       parsestrip(pop!(parsed, "cell_length_b")::String),
                       parsestrip(pop!(parsed, "cell_length_c")::String)),
                      (parsestrip(pop!(parsed, "cell_angle_alpha")::String),
                       parsestrip(pop!(parsed, "cell_angle_beta")::String),
                       parsestrip(pop!(parsed, "cell_angle_gamma")::String)),
                parse.(EquivalentPosition, equivalentpositions, Ref(refid)))

    haskey(parsed, "symmetry_equiv_pos_site_id") && pop!(parsed, "symmetry_equiv_pos_site_id")
    haskey(parsed, "symmetry_cell_setting") && pop!(parsed, "symmetry_cell_setting")

    removed_identity = false
    for i in eachindex(cell.equivalents)
        eq = cell.equivalents[i]
        if isone(eq.mat) && iszero(eq.ofs)
            deleteat!(cell.equivalents, i)
            removed_identity = true
            break
        end
    end
    @assert removed_identity

    labels =  pop!(parsed, "atom_site_label")::Vector{String}
    _symbols = haskey(parsed, "atom_site_type_symbol") ?
                    pop!(parsed, "atom_site_type_symbol")::Vector{String} : copy(labels)
    symbols = String[]
    @inbounds for x in _symbols
        i = findfirst(!isletter, x)
        push!(symbols, isnothing(i) ? x : x[1:i-1])
    end
    pos_x = pop!(parsed, "atom_site_fract_x")::Vector{String}
    pos_y = pop!(parsed, "atom_site_fract_y")::Vector{String}
    pos_z = pop!(parsed, "atom_site_fract_z")::Vector{String}


    types = Symbol[]
    pos = Matrix{Float64}(undef, 3, natoms)
    correspondence = Dict{String, Int}()
    for i in 1:natoms
        @assert !haskey(correspondence, labels[i])
        correspondence[labels[i]] = i
        push!(types, Symbol(symbols[i]))
        pos[:,i] = parsestrip.(Float64, [pos_x[i], pos_y[i], pos_z[i]])
        pos[:,i] .-= floor.(Int, pos[:,i])
    end

    invids = sortperm(types)
    types = types[invids]
    ids = invperm(invids)
    bonds = fill(Inf32, natoms, natoms)
    if haskey(parsed, "geom_bond_atom_site_label_1") &&
       haskey(parsed, "geom_bond_atom_site_label_2")
        bond_a = pop!(parsed, "geom_bond_atom_site_label_1")::Vector{String}
        bond_b = pop!(parsed, "geom_bond_atom_site_label_2")::Vector{String}
        dists = (haskey(parsed, "geom_bond_distance") ? 
                    parsestrip.(Float32, pop!(parsed, "geom_bond_distance")::Vector{String}) :
                    fill(zero(Float32), length(bond_a)))
        for i in 1:length(bond_a)
            try
                x = correspondence[bond_a[i]]
                y = correspondence[bond_b[i]]
                bonds[x,y] = bonds[y,x] = 1.001*dists[i] # to avoid rounding errors
            catch e
                if e isa KeyError
                    @ifwarn @warn "Atom $(e.key) will be ignored since it has no placement in the CIF file."
                else
                    rethrow()
                end
            end
        end
    end

    return CIF(parsed, cell, ids, types, pos, bonds)
end



"""
    parse_arc(file)

Parse a .arc Systre archive such as the one used by the RCSR.
Return a pair `(flag, pairs)`.

`flag` is set if the archive corresponds to one generated by a compatible release
of CrystalNets. If unset, the genomes of the archive may not be the same as those
computed by CrystalNets for the same nets.
`pairs` is a `Dict{String,String}` whose entries have the form `genome => id` where `id`
is the name of the net and `genome` is the topological genome corresponding to this net
(given as a string of whitespace-separated values parseable by `PeriodicGraph`).
"""
function parse_arc(file)
    pairs = Dict{String,String}()
    curr_key = ""
    counter = 1
    firstline = readline(file)
    flag = startswith(firstline, "Made by CrystalNets.jl v")
    if flag
        flag = CRYSTAL_NETS_VERSION == VersionNumber(firstline[25:end])
    end
    for l in eachline(file)
        if length(l) > 3 && l[1:3] == "key"
            @assert isempty(curr_key)
            i = 4
            while isspace(l[i])
                i += 1
            end
            curr_key = l[i:end]
            @assert !haskey(pairs, curr_key)
        elseif length(l) > 2 && l[1:2] == "id"
            @assert !isempty(curr_key)
            i = 3
            while isspace(l[i])
                i += 1
            end
            pairs[curr_key] = l[i:end]
            curr_key = ""
        end
    end
    return flag, pairs
end

"""
    parse_arcs(file)

Parse a folder containing .arc Systre archives such as the one used by the RCSR.
Return a pair `(flag, pairs)` with the same convention than `parse_arc`
"""
function parse_arcs(path)
    combine(x, y) = x * ", " * y
    dict = Dict{String,String}()
    flag = true
    for f in readdir(path; sort=true)
        _flag, _dict = parse_arc(path*f)
        flag &= _flag
        mergewith!(combine, dict, _dict)
    end
    return flag, dict
end

function parse_atom_name(name::AbstractString)
    firstsep = findfirst(x -> ispunct(x) || isspace(x) || isnumeric(x), name)
    if firstsep isa Nothing
        return String(name)
    else
        firstsep::Int
        if firstsep != 1 && !any(isuppercase, @view name[nextind(name, firstsep):end])
            return String(name[1:prevind(name, firstsep)])
        else
            return String(name)
        end
    end
end

function parse_atom(name)
    atom = Chemfiles.Atom(name)
    set_type!(atom, parse_atom_name(name))
    return atom
end



function attribute_residues(residues, n, assert_use_existing_residues)
    m = length(residues)
    atoms_in_residues = m == 0 ? 0 : sum(length(atoms(r)) for r in residues)
    @assert atoms_in_residues <= n

    if atoms_in_residues < n
        if assert_use_existing_residues
            throw(ArgumentError("""
            Cannot use existing residues as vertices because not all atoms have an associated residue.
            To fix this, either assign a residue to each atom or provide another way to detect the vertices.
            """))
        end
        if atoms_in_residues > 0
            @ifwarn @warn "Some but not all atoms have an associated residue, so we cannot rely on existing residues"
        end
        return Int[]
    end
    attributions = zeros(Int, n)
    for i_residue in 1:m
        for atom in atoms(residues[i_residue])
            attributions[atom+1] = i_residue
        end
    end
    return attributions
end

@static if !isdefined(Chemfiles, :atoms) # up to 0.9.3 included
    function atoms(residue::Chemfiles.Residue)
        count = size(residue)
        result = Array{UInt64}(undef, count)
        Chemfiles.__check(Chemfiles.lib.chfl_residue_atoms(Chemfiles.__const_ptr(residue), pointer(result), count))
        return result
    end
end

"""
    check_collision(pos, mat)

Given a list of fractional coordinates `pos` and the matrix of the unit cell
`mat`, return a list of atoms that are suspiciously close to another atom
of the list. For each collision site, only one atom is not present in the
returned list.
"""
function check_collision(pos, mat)
    n = length(pos)
    toremove = Int[]
    for i in 1:n
        posi = pos[i]
        for j in (i+1):n
            if periodic_distance(posi, pos[j], mat) < 0.55
                push!(toremove, j)
            end
        end
    end
    if !isempty(toremove)
        @ifwarn @warn "This file contains multiple colliding atoms. Only one atom will be kept per site."
        sort!(toremove)
        unique!(toremove)
    end

    return toremove
end

function fix_atom_on_a_bond!(graph, pos, mat)
    for i in vertices(graph)
        neighs = neighbors(graph, i)
        flag = length(neighs) > 1
        while flag
            flag = false
            p = pos[i]
            for (j1, u1) in enumerate(neighs)
                vec1 = mat * (pos[u1.v] .+ u1.ofs .- p)
                for j2 in (j1+1):length(neighs)
                    u2 = neighs[j2]
                    vec2 = mat * (pos[u2.v] .+ u2.ofs .- p)
                    if angle(vec1, vec2) < 10
                        furthest = norm(vec1) < norm(vec2) ? u2 : u1
                        rem_edge!(graph, i, furthest)
                        flag = true
                        break
                    end
                end
                flag && break
            end
        end
    end
end


"""
    least_plausible_neighbours(Δs, n)

Find the positions of the n least probable neighbours of an atom, given the list
Δs of the distance between their position and that of the atom.

This function is highly empirical and should not be considered utterly reliable.
"""
function least_plausible_neighbours(Δs, n)
    m = length(Δs)
    m ≤ n && return collect(1:m) # may happen because H bonds cannot be removed
    p::Vector{Int} = sortperm(Δs)
    return p[end-n+1:end]
end

macro reduce_valence(n)
    return esc(quote
        neighs = neighbors(graph, i)
        m = length(neighs)
        m == $n && continue
        (!dofix || m < $n) && push!(invalidatoms, t)
        if dofix && m > $n
            posi = pos[i]
            Δs = [norm(mat * (pos[x.v] .+ x.ofs - posi)) for x in neighs]
            toremove = least_plausible_neighbours(Δs, m - $n)
            neighs = copy(neighs) # otherwise the list is modified by rem_edge!
            for v in toremove
                rem_edge!(graph, PeriodicEdge{N}(i, neighs[v]))
            end
        end
    end)
end

macro reduce_valence(n1, n2)
    comparison = n1 == 0 ? :(m ≤ $n2) : :($n1 ≤ m ≤ $n2)
    invalidcond = n1 == 0 ? :(!dofix) : :(!dofix || m < $n1)
    return esc(quote
        neighs = neighbors(graph, i)
        m = length(neighs)
        $comparison && continue
        ($invalidcond) && push!(invalidatoms, t)
        if dofix && m > $n2
            posi = pos[i]
            noHatoms = [x for x in neighs if types[x.v] !== :H]
            Δs = [norm(mat * (pos[x.v] .+ x.ofs - posi)) for x in noHatoms]
            toremove = least_plausible_neighbours(Δs, m - $n2)
            for v in toremove
                rem_edge!(graph, PeriodicEdge{N}(i, noHatoms[v]))
            end
        end
    end)
end


"""
    fix_valence!(graph::PeriodicGraph, pos, types, mat, ::Val{dofix}) where dofix

Attempt to ensure that the coordinence of certain atoms are at least plausible
by removing some edges from the graph.
These atoms are H, halogens, O, N and C.
if `dofix` is set, actually modify the graph; otherwise, only emit a warning.
In both cases, return a list of atoms with invalid coordinence.
"""
function fix_valence!(graph::PeriodicGraph{N}, pos, types, mat, ::Val{dofix}, options) where {N,dofix}
    # Small atoms valence check
    n = length(types)
    invalidatoms = Set{Symbol}()
    # First pass over H, since those are likely bonded to their closest neighbor
    passO = Int[]
    passCN = Int[]
    for i in 1:n
        t = types[i]
        if t === :H
            @reduce_valence 1
        elseif t === :O
            push!(passO, i)
        elseif t === :C || t === :N
            push!(passCN, i)
        end
    end
    for i in passO
        t = :O
        if options.clustering_mode == ClusteringMode.MOF
            @reduce_valence 0 4 # oxo-clusters
        else
            @reduce_valence 0 2
        end
    end
    for i in passCN
        t = types[i]
        if options.clustering_mode == ClusteringMode.MOF
            @reduce_valence 2 5
        else
            @reduce_valence 2 4
        end
    end
    if !isempty(invalidatoms)
        s = String.(collect(invalidatoms))
        @ifwarn @warn (dofix ? "After attempted fix, f" : "F")*"ound $(join(s, ", ", " and ")) with invalid number of bonds."
    end
    return invalidatoms
end

"""
    sanitize_removeatoms!(graph, pos, types, mat)

Special heuristics to remove atoms that seem to arise from an improper cleaning of the file.
Currently implmented:
- C atoms suspiciously close to metallic atoms.
- O atoms with 4 coplanar bonds.
"""
function sanitize_removeatoms!(graph::PeriodicGraph{N}, pos, types, mat, options) where N
    toremove = Set{Int}()
    flag = true
    dofix = true # for the @reduce_valence macro
    for (i, t) in enumerate(types)
        if t === :O
            continue
            @reduce_valence 0 4
            # at this point, the valence is 4 since @reduce_valence would continue otherwise
            neighs = neighbors(graph, i)
            p = pos[i]
            lengths = [norm(mat * (pos[u.v] .+ u.ofs .- p)) for u in neighs]
            if flag && any(>(2.6), lengths)
                @show options.name
                flag = false
            end
        elseif ismetal[atomic_numbers[t]]
            for u in neighbors(graph, i)
                if types[u.v] === :C
                    u.v ∈ toremove && continue
                    bondlength = Float64(norm(mat * (pos[u.v] .+ u.ofs .- pos[i])))
                    bondlength > 1.45 && continue
                    @ifwarn if isempty(toremove)
                        @warn "C suspiciously close to a metal (bond length: $bondlength) will be removed"
                    end
                    push!(toremove, u.v)
                end
            end
        end
    end

    rem = sort!(collect(toremove))
    if isempty(rem)
        return false, Int[]
    end
    return true, rem_vertices!(graph, rem)
end


function remove_triangles!(graph::PeriodicGraph{N}, pos, types, mat, options) where N
    preprocessed = Dict{PeriodicEdge{N},Tuple{Float64,Bool}}()
    removeedges = Dict{PeriodicEdge{N},Tuple{PeriodicEdge{N},PeriodicEdge{N}}}()
    rev_removeedges = Dict{PeriodicEdge{N},Set{PeriodicEdge{N}}}()
    toinvestigate = collect(edges(graph))
    while !isempty(toinvestigate)
        new_toinvestigate = Set{PeriodicEdge{N}}()
        for e in toinvestigate
            s, d = e.src, e.dst.v
            bondlength, supcutoff = get!(preprocessed, e) do
                cutoff = ismetal[atomic_numbers[types[s]]] || ismetal[atomic_numbers[types[d]]] ? 2.5 : 3.0
                _bondlength = norm(mat * (pos[d] .+ e.dst.ofs .- pos[s]))
                _bondlength, _bondlength > cutoff
            end
            if supcutoff
                neigh_s = neighbors(graph, s)
                neigh_d = [PeriodicVertex{N}(x.v, x.ofs .+ e.dst.ofs) for x in neighbors(graph, d)]
                for x in intersect(neigh_s, neigh_d) # triangle
                    l1 = norm(mat * (pos[x.v] .+ x.ofs .- pos[d] .- e.dst.ofs))
                    l1 < bondlength || continue
                    l2 = norm(mat * (pos[x.v] .+ x.ofs .- pos[s]))
                    l2 < bondlength || continue
                    if bondlength*bondlength > min(9.0, l1*l1 + l2*l2)
                        e1 = PeriodicEdge(s, x)
                        e1 = PeriodicGraphs.isindirectedge(e1) ? reverse(e1) : e1
                        if haskey(removeedges, e1)
                            push!(new_toinvestigate, e)
                            continue
                        end
                        e2 = PeriodicEdge(d, x.v, .- e.dst.ofs .- x.ofs)
                        e2 = PeriodicGraphs.isindirectedge(e2) ? reverse(e2) : e2
                        if haskey(removeedges, e2)
                            push!(new_toinvestigate, e)
                            continue
                        end
                        removeedges[e] = (e1, e2)
                        push!(get!(rev_removeedges, e1, Set{PeriodicEdge{N}}()), e)
                        push!(get!(rev_removeedges, e2, Set{PeriodicEdge{N}}()), e)
                        invalidate = get(rev_removeedges, e, nothing)
                        if invalidate isa Set{PeriodicEdge{N}}
                            # This means that e was part of some triangles but no longer exists
                            for ex in invalidate
                                ea, eb = removeedges[ex]
                                ey = ea == e ? eb : ea
                                delete!(rev_removeedges[ey], ex)
                                delete!(removeedges, ex)
                                push!(new_toinvestigate, ex)
                            end
                            delete!(rev_removeedges, e)
                        end
                        break
                    end
                end
            end
        end
        for e in keys(removeedges)
            rem_edge!(graph, e)
        end
        empty!(removeedges)
        empty!(rev_removeedges)
        toinvestigate = collect(new_toinvestigate)
    end
    return preprocessed
end

"""
    sanity_checks!(graph, pos, types, mat, options)

Perform some sanity checks to ensure that the detected bonds are not obviously
wrong because they are either too short or too long.
"""
function sanity_checks!(graph, pos, types, mat, options)
    ## Bond length check
    ret = false
    smallbondsflag = false
    removeedges = PeriodicEdge3D[]
    alreadywarned = Set{Tuple{Symbol,Symbol,Float16}}()
    preprocessed = remove_triangles!(graph, pos, types, mat, options)
    for e in edges(graph)
        s, d = e.src, e.dst.v
        bondlength, supcutoff = preprocessed[e]
        if supcutoff # This bond could be spurious
            if bondlength > 3 && options.cutoff_coeff ≤ 0.8
                (order_s, order_d), blength = minmax(types[s], types[d]), Float16(bondlength)
                if (order_s, order_d, blength) ∉ alreadywarned
                    push!(alreadywarned, (order_s, order_d, blength))
                    @ifwarn @warn "Suspiciously large bond found: $blength pm between $order_s and $order_d." *
                        (bondlength > 4 ? " Such bonds are probably spurious and will be deleted." : "")
                    ret = true
                end
                if bondlength > 4
                    push!(removeedges, e)
                end
            end
        elseif (bondlength < 0.65 && types[s] !== :H && types[d] !== :H)
            smallbondsflag = true
            push!(removeedges, e)
        end
    end
    if options.bonding_mode == BondingMode.Auto
        if !isempty(removeedges)
            @ifwarn if smallbondsflag
                @warn "Suspicious small bond lengths found. Such bonds are probably spurious and will be deleted."
                @info "To force retaining these bonds, use --bond-detect=input or --bond-detect=guess"
            end
            if !(options.dryrun isa Nothing)
                options.dryrun[:try_no_Auto_bonds] = nothing
                options.dryrun[:suspect_smallbonds] = union(
                    Set{Symbol}([types[src(e)] for e in removeedges]),
                    Set{Symbol}([types[dst(e)] for e in removeedges]))
            end
        end
        for e in removeedges
            rem_edge!(graph, e)
        end
    end
    return ret
end

"""
    remove_homoatomic_bonds!(graph::PeriodicGraph, types, targets)

Remove from the graph all bonds of the form X-X where X is an atom in `targets`.
"""
function remove_homoatomic_bonds!(graph::PeriodicGraph{D}, types, targets) where D
    isempty(targets) && return
    n = length(types)
    for i in 1:n
        t = types[i]
        t ∈ targets || continue
        rem_edges = PeriodicVertex{D}[]
        for x in neighbors(graph, i)
            types[x.v] == t || continue
            push!(rem_edges, x)
        end
        for x in rem_edges
            rem_edge!(graph, i, x)
        end
    end
    nothing
end


function parse_as_cif(cif::CIF, options, name)
    guessed_bonds = false
    n = length(cif.ids)
    ignored = Int[]
    types = Symbol[]
    pos = SVector{3,Float64}[]
    occupancies = options.ignore_low_occupancy ?
                        get(cif.cifinfo, :atom_site_occupancy, ones(n)) : ones(n)
    for i in 1:n
        typ = cif.types[cif.ids[i]]
        if typ ∈ options.ignore_atoms || occupancies[i] < 0.5
            push!(ignored, i)
            continue
        end
        push!(types, Symbol(parse_atom_name(String(typ))))
        push!(pos, cif.pos[:,i])
        #push!(pos, cif.cell.mat * cif.pos[:,i])
    end
    if all(==(Inf32), cif.bonds)
        if options.bonding_mode == BondingMode.Input
            throw(ArgumentError("Cannot use input bonds since there are none. Use another option for --bonds-detect or provide bonds in the CIF file."))
        end
        guessed_bonds = true

        bonds = guess_bonds(pos, types, Float64.(cif.cell.mat), options)
    else
        bonds = Tuple{Int,Int,Float32}[]
        _i = 1 # correction to i based on ignored atoms
        current_ignored_i = get(ignored, 1, 0)
        for i in 1:n
            if i == current_ignored_i
                _i += 1
                current_ignored_i = get(ignored, _i, 0)
                continue
            end
            _j = _i # correction to j based on ignored atoms
            current_ignored_j = current_ignored_i
            for j in (i+1):n
                if j == current_ignored_j
                    _j += 1
                    current_ignored_j = get(ignored, _j, 0)
                    continue
                end
                dist = cif.bonds[i,j]
                if dist < Inf32
                    push!(bonds, (i - _i + 1, j - _j + 1, dist))
                end
            end
        end
    end
    n -= length(ignored)

    cell = Cell(cif.cell.mat)
    return finalize_checks(cell, pos, types, Int[], bonds, guessed_bonds, options, name)
end


function parse_as_chemfile(frame, options, name)
    types = Symbol[]
    for i in Int(size(frame))-1:-1:0
        typ = Symbol(type(Chemfiles.Atom(frame, i)))
        if typ ∈ options.ignore_atoms
            Chemfiles.remove_atom!(frame, i)
        else
            push!(types, typ)
        end
    end

    _pos = collect(eachcol(positions(frame)))
    cell = Cell(SMatrix{3,3,BigFloat}(matrix(Chemfiles.UnitCell(frame)))')

    pos::Vector{SVector{3,Float64}} = Ref(inv(cell.mat)) .* _pos

    toremove = check_collision(pos, cell.mat)
    if !isempty(toremove)
        deleteat!(types, toremove)
        deleteat!(pos, toremove)
        for j in Iterators.reverse(toremove)
            Chemfiles.remove_atom!(frame, j-1)
        end
        if !(options.dryrun isa Nothing)
            options.dryrun[:collisions] = nothing
        end
    end

    n = length(pos)
    guessed_bonds = false
    topology = Chemfiles.Topology(frame)
    if Chemfiles.bonds_count(topology) == 0
        guessed_bonds = true
        bonds = guess_bonds(pos, types, Float64.(cell.mat), options)
        for (u, v, _) in bonds
            Chemfiles.add_bond!(frame, u-1, v-1)
        end
    else
        bonds = [(a+1, b+1, -1f0) for (a,b) in eachcol(Chemfiles.bonds(topology))]
        if !(options.dryrun isa Nothing) && options.bonding_mode == BondingMode.Auto
            options.dryrun[:try_Input_bonds] = nothing
        end
    end

    topology = Chemfiles.Topology(frame) # Just a precaution since frame was possibly modified
    m = Int(Chemfiles.count_residues(topology))
    residues = [Chemfiles.Residue(topology, i) for i in 0:(m-1)]

    attributions = attribute_residues(residues, n, options.clustering_mode == ClusteringMode.Input)
    return finalize_checks(cell, pos, types, attributions, bonds, guessed_bonds, options, name)
end


function finalize_checks(cell, pos, types, attributions, bonds, guessed_bonds, options, name)
    n = length(pos)

        mat = Float64.(cell.mat)
    graph = PeriodicGraph3D(n, edges_from_bonds(bonds, mat, pos))

    if options.bonding_mode != BondingMode.Input
        do_permutation, vmap = sanitize_removeatoms!(graph, pos, types, mat, options)
        if do_permutation
            types = types[vmap]
            pos = pos[vmap]
            if !isempty(attributions)
                attributions = attributions[vmap]
            end
        end
        fix_atom_on_a_bond!(graph, pos, mat)
        bad_valence = !isempty(fix_valence!(graph, pos, types, mat, Val(false), options))
        recompute_bonds = bad_valence || sanity_checks!(graph, pos, types, mat, options)
        if recompute_bonds
            if !guessed_bonds
                @ifwarn begin
                    @warn "Disregarding all bonds from the input file."
                    @info "To force retaining the initial bonds, use --bond-detect=input"
                end
                bonds = guess_bonds(pos, types, mat, options)
                guessed_bonds = true
                graph = PeriodicGraph3D(n, edges_from_bonds(bonds, cell.mat, pos))
            end
            invalidatoms = fix_valence!(graph, pos, types, mat, Val(true), options)
            remaining_not_fixed = !isempty(invalidatoms)
            @ifwarn if remaining_not_fixed
                @warn "Remaining atoms with invalid valence. Proceeding anyway."
            end
            if !(options.dryrun isa Nothing)
                options.dryrun[:invalidatoms] = invalidatoms
            end
            recompute_bonds = sanity_checks!(graph, pos, types, cell.mat, options)
            @ifwarn if recompute_bonds
                @warn "Remaining bonds of suspicious lengths. Proceeding anyway."
            end
        end
    end

    if !guessed_bonds
        remove_homoatomic_bonds!(graph, types, options.ignore_homoatomic_bonds)
    end

    if isempty(attributions)
        crystalnothing = Crystal{Nothing}(cell, types, pos, graph, options)
        export_default(crystalnothing, "input", name, options.export_input)
        return crystalnothing
    else
        crystalclusters = Crystal{Clusters}(cell, types, regroup_sbus(graph, attributions),
                                            pos, graph, options)
        export_default(crystalclusters, "input", name, options.export_input)
        return crystalclusters
    end
end


"""
       parse_chemfile(path, options::Options)

Parse a file given in any reckognised chemical format and extract the topological
information.
Such format can be .cif or any file format reckognised by Chemfiles.jl that
contains all the necessary topological information.
"""
function parse_chemfile(_path, options::Options)
    # Separate the cases unhandled by Chemfiles from the others
    path = expanduser(_path)
    name = splitext(splitdir(path)[2])[1]
    if options.name == "unnamed"
        options = Options(options; name)
    end
    if lowercase(last(splitext(path))) == ".cif"
        cif = expand_symmetry(CIF(path))
        if options.authorize_pruning
            neededprune, cif = prune_collisions(cif)
            if neededprune && !(options.dryrun isa Nothing)
                options.dryrun[:collisions] = nothing
            end
        end
        return parse_as_cif(cif, options, name)
    end
    frame = read(Chemfiles.Trajectory(path))
    return parse_as_chemfile(frame, options, name)
end
parse_chemfile(path; kwargs...) = parse_chemfile(path, Options(; kwargs...))
