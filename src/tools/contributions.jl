
function _error_contrib_index(i, itype)
    throw(ArgumentError(chomp("""
        Atom index $i with type index $itype are not available in the contribution matrix. 
        There is something wrong in the way the group selection was provided.
    """)))
end

function _error_contrib_name(name)
    throw(ArgumentError(chomp("""
        Atom name $name is not available in the contribution matrix. 
        There is something wrong in the way the group selection was provided.
    """)))
end

function contributions(R::Result, group::Union{SoluteGroup,SolventGroup})
    if typeof(group) == SoluteGroup
        struct_data = R.solute
        contrib_data = R.solute_group_contributions
    elseif typeof(group) == SolventGroup
        struct_data = R.solvent
        contrib_data = R.solvent_group_contributions
    end
    # If the index or group name was provided, just return the corresponding contribution
    if isnothing(group.indices)
        igroup = if !isnothing(group.group_index)  
           group.group_index
        elseif !isnothing(group.group_name) 
           findfirst(isequal(group_name), struct_data.group_names)
        end
        if isnothing(igroup) || igroup > size(contrib_data, 2)
            throw(ArgumentError("Group $igroup not found in the contribution matrix."))
        end
        return contrib_data[:, igroup]
    end
    # If, instead, atom indices or names were provided, sum over the contributions of the atoms.
    # This sum is different if the structure contanis one or more than one molecule.
    # If the structure has more than one molecule, than the indices are indices of 
    # the atoms *within* the molecule. 
    c = zeros(size(contrib_data, 1))
    if !isnothing(group.atom_indices) 
        if struct_data.nmols == 1 
            for i in group.atom_indices
                i > size(contrib_data, 2) && _error_contrib_index(i, i)
                c += @view(contrib_data[:, i])
            end
        else
            for i in group.atom_indices
                itype = (i - 1) ÷ struct_data.natomspermol + 1
                itype > size(contrib_data, 2) && _error_contrib_index(i, itype)
                c += @view(contrib_data[:, itype])
            end
        end
    end
    if !isnothing(group.atom_names) 
        if struct_data.nmols == 1 
            for name in group.atom_names
                i = findfirst(isequal(name), struct_data.names)
                (isnothing(i) || i > size(contrib_data, 2)) && _error_contrib_name(name)
                c += @view(contrib_data[:, i])
            end
        else
            for name in group.atom_names
                i = findfirst(isequal(name), struct_data.names)
                itype = (i - 1) ÷ struct_data.natomspermol + 1
                (isnothing(i) || itype > size(contrib_data, 2)) && _error_contrib_name(name)
                c += @view(contrib_data[:, itype])
            end
        end
    end
    return c
end


#
# If a residue of type PDBTools.Residue is provided
#
function contributions(
    s::AtomSelection,
    atom_contributions::Matrix{Float64},
    residue::PDBTools.Residue;
    warning = true,
)
    (warning && s.nmols > 1) && warning_nmols_types()
    indices = collect(residue.range)
    # Check which types of atoms belong to this selection
    selected_types = which_types(s, indices, warning = warning)
    return contributions(s, atom_contributions, selected_types)
end

function warning_nmols_types()
    println("""
        WARNING: There is more than one molecule in this selection.
                 Contributions are summed over all atoms of the same type.
    """)
end

@testitem "solute position" begin
    using ComplexMixtures
    using PDBTools
    using ComplexMixtures.Testing

    dir = "$(Testing.data_dir)/PDB"
    atoms = readPDB("$dir/trajectory.pdb", "model 1")

    solute = AtomSelection(select(atoms, "resname TMAO and resnum 1"), nmols = 1)
    solvent = AtomSelection(
        select(atoms, "resname TMAO and resnum 2 or resname TMAO and resnum 3"),
        nmols = 2,
    )

    traj = Trajectory("$dir/trajectory.pdb", solute, solvent, format = "PDBTraj")
    results = mddf(traj)

    # solute contributions fetching
    N_contributions = contributions(solute, results.solute_atom, ["N"])
    @test length(N_contributions) == 500

    C1_contributions = contributions(solute, results.solute_atom, ["C1"])
    @test length(C1_contributions) == 500

    H33_contributions = contributions(solute, results.solute_atom, ["H33"])
    @test length(H33_contributions) == 500

    # solvent contributions fetching
    N_contributions = contributions(solvent, results.solvent_atom, ["N"])
    @test length(N_contributions) == 500

    C1_contributions = contributions(solvent, results.solvent_atom, ["C1"])
    @test length(C1_contributions) == 500

    H33_contributions = contributions(solvent, results.solvent_atom, ["H33"])
    @test length(H33_contributions) == 500

end
