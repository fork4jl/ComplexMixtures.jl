"""
    grid3D(
        result::Result, atoms, output_file::Union{Nothing,String} = nothing; 
        dmin=1.5, ddax=5.0, step=0.5, silent = false,
    )

This function builds the grid of the 3D density function and fills an array of
mutable structures of type Atom, containing the position of the atoms of 
grid, the closest atom to that position, and distance. 

`result` is a `ComplexMixtures.Result` object 
`atoms` is a vector of `PDBTools.Atom`s with all the atoms of the system. 
`output_file` is the name of the file where the grid will be written. If `nothing`, the grid is only returned as a matrix. 

`dmin` and `dmax` define the range of distance where the density grid will be built, and `step`
defines how fine the grid must be. Be aware that fine grids involve usually a very large (hundreds
of thousands points).

`silent` is a boolean to suppress the progress bar.

### Example

```julia-repl
julia> using ComplexMixtures, PDBTools

julia> atoms = readPDB("./system.pdb");

julia> R = ComplexMixtures.load("./results.json");

julia> grid = grid3D(R, atoms, "grid.pdb");
```

`grid` will contain a vector of `Atom`s with the information of the MDDF at each grid point, and the
same data will be written in the `grid.pdb` file. This PDB file can be opened in VMD, for example, and contain
in the `beta` field the contribution of each protein residue to the MDDF at each point in space relative to the 
protein, and in the `occupancy` field the distance to the protein. Examples of how this information can be
visualized are provided in the user guide of `ComplexMixtures`. 

"""
function grid3D(
    result::Result, 
    atoms, 
    output_file::Union{Nothing,String} = nothing; 
    dmin=1.5, 
    dmax=5.0, 
    step=0.5,
    silent = false,
)

    # Simple function to interpolate data
    interpolate(x₁, x₂, y₁, y₂, xₙ) = y₁ + (y₂ - y₁) / (x₂ - x₁) * (xₙ - x₁)

    # Maximum and minimum coordinates of the solute
    solute_atoms = PDBTools.select(atoms, by = at -> at.index in result.solute.indices)
    lims = PDBTools.maxmin(solute_atoms)
    n = @. ceil(Int, (lims.xlength + 2 * dmax) / step + 1)

    # Building the grid with the nearest solute atom information
    igrid = 0
    grid = PDBTools.Atom[]
    silent || (p = Progress(prod(n), "Building grid..."))
    for ix = 1:n[1], iy = 1:n[2], iz = 1:n[3]
        silent || next!(p)
        x = lims.xmin[1] - dmax + step * (ix - 1)
        y = lims.xmin[2] - dmax + step * (iy - 1)
        z = lims.xmin[3] - dmax + step * (iz - 1)
        rgrid = -1
        _, iat, r = PDBTools.closest(SVector(x, y, z), solute_atoms)
        if (dmin < r < dmax)
            if rgrid < 0 || r < rgrid
                at = solute_atoms[iat]
                # Get contribution of this atom to the MDDF
                c = contributions(result, SoluteGroup([at.index_pdb]))
                # Interpolate c at the current distance
                iright = findfirst(d -> d > r, result.d)
                ileft = iright - 1
                cᵣ = interpolate(
                    result.d[ileft],
                    result.d[iright],
                    c[ileft],
                    c[iright],
                    r,
                )
                if cᵣ > 0
                    gridpoint = PDBTools.Atom(
                        index = at.index,
                        index_pdb = at.index_pdb,
                        name = at.name,
                        chain = at.chain,
                        resname = at.resname,
                        resnum = at.resnum,
                        x = x,
                        y = y,
                        z = z,
                        occup = r,
                        beta = cᵣ,
                        model = at.model,
                        segname = at.segname,
                    )
                    if rgrid < 0
                        igrid += 1
                        push!(grid, gridpoint)
                    elseif r < rgrid
                        grid[igrid] = gridpoint
                    end
                    rgrid = r
                end # cᵣ>0
            end # rgrid
        end # dmin/dmax
    end #ix

    # Now will scale the density to be between 0 and 99.9 in the temperature
    # factor column, such that visualization is good enough
    bmin, bmax = +Inf, -Inf
    for gridpoint in grid
        bmin = min(bmin, gridpoint.beta)
        bmax = max(bmax, gridpoint.beta)
    end
    for gridpoint in grid
        gridpoint.beta = (gridpoint.beta - bmin) / (bmax - bmin)
    end

    if !isnothing(output_file)
        PDBTools.writePDB(grid, output_file)
        silent || println("Grid written to $output_file")
    end
    return grid
end
