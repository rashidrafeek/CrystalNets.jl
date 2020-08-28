## Handling of the topological archive internally used to reckognize topologies.
import Serialization
import Pkg

const CRYSTAL_NETS_VERSION = VersionNumber(Pkg.TOML.parsefile(joinpath(@__DIR__, "..", "Project.toml"))["version"])
const arc_location = normpath(joinpath(@__DIR__, "default.arc"))
const CRYSTAL_NETS_ARCHIVE = if isfile(arc_location)
    flag, parsed = parse_arc(arc_location)
    if !flag
        error("""CrystalNets.jl appears to have a broken installation (the archive version is older than that package's).
        Please rebuild CrystalNets.jl with `import Pkg; Pkg.build("CrystalNets")`.
        """)
    end
    parsed
else
    error("""CrystalNets.jl appears to have a broken installation (missing default archive).
          Please rebuild CrystalNets.jl with `import Pkg; Pkg.build("CrystalNets")`.

          This issue may be due to an error while using `CrystalNets.clean_default_archive!(...)`.
          If you have not encountered any such error and you did not modify or erase the archive located at $arc_location please open an issue at https://github.com/coudertlab/CrystalNets.jl/issues/new
          """)
end
const REVERSE_CRYSTAL_NETS_ARCHIVE = Dict{String,String}(last(x) => first(x) for x in CRYSTAL_NETS_ARCHIVE)


function validate_archive(custom_arc)::Dict{String,String}
    arc = try
        Serialization.deserialize(custom_arc)
    catch
        nothing
    end
    if arc isa Dict{String,String} && !isempty(arc) && isnumeric(first(first(keys(arc))))
        @info "Processing input as a serialized CrystalNets.jl archive"
    else
        try
            flag, parsed = parse_arc(custom_arc)
            if flag
                arc = parsed
            else
                @info "Processing input as a topological .arc file"
                if occursin("Made by CrystalNets.jl", readline(custom_arc))
                    @info "This archive was generated by an older version of CrystalNets."
                end
                @info "Keys will be converted to the topological genome used by CrystalNets. This may take a while."
                arc = Dict([string(topological_genome(PeriodicGraph3D(first(x)))) => last(x) for x in parsed if PeriodicGraph(first(x)) isa PeriodicGraph3D])
            end
        catch
            error("""
            Impossible to parse input as a topological archive. Please use a format
            similar to that of the RCSR Systre .arc file, with for each entry at
            least the "id" and "key" fields.

            This error may also occur if the given archive was empty. If you
            wish to set an empty archive, use `CrystalNets.empty_default_archive!()`
            """)
        end
    end
    return arc
end

"""
    clean_default_archive!(custom_arc=nothing; validate=true, refresh=true)

Erase the default archive used by CrystalNets.jl to reckognize known topologies.

If no parameter is provided, the new default archive is the RCSR Systre archive.
Otherwise it is replaced by the file located at `custom_arc`. In this case, the
`validate` parameter controls whether the new file is checked and converted to a
format usable by CrystalNets.jl. If unsure, leave it set.

The `refresh` optional parameter controls whether the current archive should be
replaced by the new default one.

!!! warning
    This archive will be kept and used for subsequent runs of CrystalNets.jl, even
    if you restart your Julia session.

    To only change the archive for the current session, use `CrystalNets.change_current_archive!(custom_arc)`.

    See also `refresh_current_archive!` for similar uses.

!!! warning
    Using an invalid archive will make CrystalNets.jl unusable. If this happens,
    simply run `CrystalNets.clean_default_archive!()` to revert to the RCSR Systre
    default archive.

See also `add_to_current_archive!`, `change_current_archive!`, `refresh_current_archive!`,
`set_default_archive!`, `empty_default_archive!`
"""
function clean_default_archive!(custom_arc=nothing; validate=true, refresh=true)
    rm(arc_location; force=true)
    if custom_arc isa Nothing
        cp(joinpath(@__DIR__, "..", "deps", "RCSR.arc"), arc_location)
    else
        if validate
            arc = validate_archive(custom_arc)
            export_arc(arc_location, false, arc)
        else
            cp(custom_arc, arc_location)
        end
    end
    if refresh
        refresh_current_archive!()
    end
    nothing
end

"""
    set_default_archive!()

Set the current archive as the new default archive.

!!! warning
    This archive will be kept and used for subsequent runs of CrystalNets.jl, even
    if you restart your Julia session.

See also `add_to_current_archive!`, `change_current_archive!`, `refresh_current_archive!`,
`clean_default_archive!`, `empty_default_archive!`
"""
function set_default_archive!()
    global CRYSTAL_NETS_ARCHIVE
    export_arc(arc_location)
end

"""
    empty_default_archive!(; refresh=true)

Empty the default archive. This will prevent CrystalNets from reckognizing any
topology before they are explicitly added.

The `refresh` optional parameter controls whether the current archive should also
be emptied.

!!! warning
    This empty archive will be kept and used for subsequent runs of CrystalNets.jl, even
    if you restart your Julia session. If you only want to empty the current archive,
    use `empty!(CrystalNets.CRYSTAL_NETS_ARCHIVE)`.

See also `add_to_current_archive!`, `change_current_archive!`, `refresh_current_archive!`,
`clean_default_archive!`, `set_default_archive!`
"""
function empty_default_archive!(; refresh=true)
    global CRYSTAL_NETS_ARCHIVE
    global REVERSE_CRYSTAL_NETS_ARCHIVE
    export_arc(arc_location, true)
    if refresh
        empty!(CRYSTAL_NETS_ARCHIVE)
        empty!(REVERSE_CRYSTAL_NETS_ARCHIVE)
    end
    nothing
end


function _change_current_archive!(newarc)
    global CRYSTAL_NETS_ARCHIVE
    global REVERSE_CRYSTAL_NETS_ARCHIVE
    empty!(CRYSTAL_NETS_ARCHIVE)
    empty!(REVERSE_CRYSTAL_NETS_ARCHIVE)
    merge!(CRYSTAL_NETS_ARCHIVE, newarc)
    merge!(REVERSE_CRYSTAL_NETS_ARCHIVE,
           Dict{String,String}(last(x) => first(x) for x in CRYSTAL_NETS_ARCHIVE))
    nothing
end

"""
    change_current_archive!(custom_arc; validate=true)

Erase the current archive used by CrystalNets.jl to reckognize known topologies and
replace it with the archive stored in the file located at `custom_arc`.

The `validate` optional parameter controls whether the new file is checked and converted
to a format usable by CrystalNets.jl. If unsure, leave it set.

!!! note
    This modification will only last for the duration of this Julia session.

    If you wish to change the default archive and use it for subsequent runs, use
    `CrystalNets.clean_default_archive!`.

!!! warning
    Using an invalid archive will make CrystalNets.jl unusable. If this happens,
    simply run `CrystalNets.refresh_current_archive!()` to revert to the
    default archive.

See also `add_to_current_archive!`, `refresh_current_archive!`, `clean_default_archive!`,
`set_default_archive!`, `empty_default_archive!`
"""
function change_current_archive!(custom_arc; validate=true)
    arc::Dict{String,String} = if validate
         validate_archive(custom_arc)
    else
        last(parse_arc(custom_arc))
    end
    _change_current_archive!(arc)
end

"""
    refresh_current_archive!()

Revert the current topological archive to the default one.

See also `add_to_current_archive!`, `change_current_archive!`, `clean_default_archive!`,
`set_default_archive!`, `empty_default_archive!`
"""
function refresh_current_archive!()
    _change_current_archive!(last(parse_arc(arc_location)))
end


function _update_archive!(id, genome)
    global CRYSTAL_NETS_ARCHIVE
    global REVERSE_CRYSTAL_NETS_ARCHIVE
    CRYSTAL_NETS_ARCHIVE[genome] = id
    REVERSE_CRYSTAL_NETS_ARCHIVE[id] = genome
    nothing
end

"""
    add_to_current_archive!(id, genome)

Mark `genome` as the topological genome associated with the name `id` in the
current archive.

The input `id` and `genome` are not modified by this operation.

!!! note
    This modification will only last for the duration of this Julia session.

    If you wish to save the archive and use it for subsequent runs, use
    `CrystalNets.set_default_archive!` after calling this function.

See also `change_current_archive!`, `refresh_current_archive!`, `clean_default_archive!`,
`set_default_archive!`, `empty_default_archive!`
"""
function add_to_current_archive!(id::AbstractString, genome::AbstractString)
    if !isnumeric(first(genome))
        throw(ArgumentError("""
            This genome ("$genome") does not look like a genome. Are you sure you did not mix `id` and `genome`?

            If you really want to associate this id with this genome, use `CrystalNets._update_archive!(id, genome)`
            """))
    end
    global CRYSTAL_NETS_ARCHIVE
    for (x,y) in CRYSTAL_NETS_ARCHIVE
        if x == genome
            y == id && return
            throw(ArgumentError("""
                This genome is already registered under the name "$y".

                If you really want to change the name associated with it, use `CrystalNets._update_archive!(id, genome)`
                """))
        end
        if y == id
            throw(ArgumentError("""
                The name $id already corresponds to a different genome: "$x"

                If you really want to store another genome with the same name, use `CrystalNets._update_archive!(id, genome)`
                """))
        end
    end
    _update_archive!(id, genome)
end
