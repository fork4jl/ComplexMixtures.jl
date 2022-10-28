
module FileOperations

#
# Function that determines the basename of a file, removing the path and the extension
#
clearname(filename::String) = remove_extension(basename(filename))

#
# Function that removes the extension of a file name
#
remove_extension(file::String) = file[1:findlast(==('.'), file)-1]

#
# Function that return only the extension of the file
#
file_extension(file::String) = file[findlast(==('.'), file)+1:end]

#
# Function that determines if a character is empty
#
empty_char(c::Char) = in(c,(Char(9),Char(32)))

#
# Function that checks if a line is a comment line or if it is empty
#
function commentary(s::String) 
    i = findfirst(c -> !(empty_char(c)), s) 
    return isnothing(i) || s[i] == '#'
end

end # module


"""

$(TYPEDEF)

Structure to contain the names of the output files.

$(TYPEDFIELDS)

"""
@with_kw mutable struct OutputFiles
    output::String
    solute_atoms::String
    solvent_atoms::String
end

"""

$(TYPEDEF)

Unit conversions.

$(TYPEDFIELDS)

"""
@with_kw struct Units
    mole = 6.022140857e23
    Angs3tocm3 = 1e24
    Angs3toL = 1e27
    Angs3tocm3permol = mole / Angs3tocm3
    Angs3toLpermol = mole / Angs3toL
    SitesperAngs3tomolperL = Angs3toL / mole
end
const units = Units()

#
# Decoration and title
#
"""

const bars = "-------------------------------------------------------------------------------"

atoms_str(n) = "$n $(n == 1 ? "atom" : "atoms")"
mol_str(n) = "$n $(n == 1 ? "molecule" : "molecules")"

"""

Print some information about the run.


"""
function title(R::Result, solute::Selection, solvent::Selection, nspawn::Int)
    println(bars)
    println("Starting MDDF calculation in parallel:")
    println("  $(R.nframes_read) frames will be considered")
    println("  Number of calculation threads: ", nspawn)
    println("  Solute: $(atoms_str(solute.natoms)) belonging to $(mol_str(solute.nmols)).")
    println("  Solvent: $(atoms_str(solvent.natoms)) belonging to $(mol_str(solvent.nmols)).")

end

function title(R::Result, solute::Selection, solvent::Selection)
    println(bars)
    println("Starting MDDF calculation:")
    println("  $(R.nframes_read) frames will be considered")
    println("  Solute: $(atoms_str(solute.natoms)) belonging to $(mol_str(solute.nmols)).")
    println("  Solvent: $(atoms_str(solvent.natoms)) belonging to $(mol_str(solvent.nmols))")

end

```
writexyz(x::Vector{T}, file::String) where T <: AbstractVector
```

Print test xyz file.

"""
function writexyz(x::Vector{T}, file::String) where {T<:AbstractVector}
    f = open(file, "w")
    nx = length(x)
    println(f, nx)
    println(f, "title")
    for i = 1:nx
        println(f, "H $(x[i][1]) $(x[i][2]) $(x[i][3])")
    end
    close(f)
    nothing
end