#
# Structure to contain trajectories read by the Chemfiles package. Many formats should
# be available through this interface, including the NamdDCD which are provided independently
# as an example. 
#
import Chemfiles

"""

$(TYPEDEF)

Structure to contain a trajectory as read by Chemfiles.jl

$(TYPEDFIELDS)

"""
struct ChemFile{T<:AbstractVector} <: Trajectory

    #
    # Mandatory data for things to work
    #
    filename::String
    format::AbstractString
    stream::Stream{<:Chemfiles.Trajectory} # mutable such that we can close it and open it again
    nframes::Int64

    # Solute and solvent data
    solute::Selection
    solvent::Selection

    # Coordinates of the solute and solvent atoms in a frame (natoms,3) for each array:
    x_solute::Vector{T}  # solute.natoms vectors of length 3 (preferentially static vectors)
    x_solvent::Vector{T} # solvent.natoms vectors of lenght 3 (preferentially static vectors)

    #
    # Additional data required for input/output functions
    #
    natoms::Int64

end

"""
    ChemFile(filename::String, solute::Selection, solvent::Selection;format="" , T::Type = SVector{3,Float64})

Function open will set up the IO stream of the trajectory, fill up the number of frames field and additional parameters if required.

"""
function ChemFile(
    filename::String,
    solute::Selection,
    solvent::Selection;
    format = "",
    T::Type = SVector{3,Float64},
)

    st = redirect_stdout(() -> Chemfiles.Trajectory(filename, 'r', format), devnull)

    # Get the number of frames (the output of Chemfiles comes in UInt64 format, which is converted
    # to Int using (UInt % Int)
    nframes = Chemfiles.length(st) % Int

    # Read the first frame to get the number of atoms
    frame = Chemfiles.read(st)
    natoms = Chemfiles.size(frame) % Int

    # Initialize the stream struct of the Trajectory
    stream = Stream(st)

    # Return the stream closed, it is opened and closed within the mddf routine
    Chemfiles.close(st)

    return ChemFile(
        filename, # trajectory file name 
        format, # trajectory format, is provided by the user
        stream,
        nframes,
        solute,
        solvent,
        zeros(T, solute.natoms),
        zeros(T, solvent.natoms),
        natoms, # Total number of atoms
    )
end

function Base.show(io::IO, trajectory::ChemFile)
    print(io,"""
          Trajectory read by Chemfiles with:
              $(trajectory.nframes) frames.
              $(trajectory.natoms) atoms.
              PBC cell in current frame: $(trajectory.sides[1])
          """)
end

#
# Function that reads the coordinates of the solute and solvent atoms from
# the next frame of the trajectory file 
#
# The function modifies sides, x_solute and x_solvent within the trajectory structure.
# Having these vectors inside the trajectory structure avoids having to allocate
# them everytime a new frame is read
#
function nextframe!(trajectory::ChemFile{T}) where {T}

    st = stream(trajectory)

    frame = Chemfiles.read(st)
    positions = Chemfiles.positions(frame)

    # Save coordinates of solute and solvent in trajectory arrays (of course this could be avoided,
    # but the code in general is more clear aftwerwards by doing this)
    for i = 1:trajectory.solute.natoms
        trajectory.x_solute[i] = T(
            positions[1, trajectory.solute.index[i]],
            positions[2, trajectory.solute.index[i]],
            positions[3, trajectory.solute.index[i]],
        )
    end
    for i = 1:trajectory.solvent.natoms
        trajectory.x_solvent[i] = T(
            positions[1, trajectory.solvent.index[i]],
            positions[2, trajectory.solvent.index[i]],
            positions[3, trajectory.solvent.index[i]],
        )
    end

end

# Returns the unitcell of the current frame, either as a vector,
# for the case of orthorhombic cells, or as a matrix for the case of triclinic cells
getunitcell(trajectory::ChemFile) = transpose(Chemfiles.UnitCell(Chemfiles.Frame(trajectory.stream)))

#
# Function that closes the IO Stream of the trajectory
#
closetraj!(trajectory::ChemFile) = Chemfiles.close(stream(trajectory))

#
# Function to open the trajectory stream
#
function opentraj!(trajectory::ChemFile)
    st = redirect_stdout(
        () -> Chemfiles.Trajectory(trajectory.filename, 'r', trajectory.format),
        devnull,
    )
    set_stream!(trajectory, st)
end

#
# Function that returns the trajectory in position to read the first frame
#
function firstframe!(trajectory::ChemFile)
    closetraj!(trajectory)
    opentraj!(trajectory)
end

@testitem "getunitcell" begin
    using ComplexMixtures
    using ComplexMixtures.Testing
    using PDBTools
    using StaticArrays

    # From the definition of the unitcell
    uc = SVector(0.0, 1.0, 1.0)
    @test ComplexMixtures.getunitcell(uc) == uc
    uc_mat = SMatrix{2,3}(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
    @test ComplexMixtures.getunitcell(uc_mat) == uc
    uc_mat = SMatrix{2,3}(1.0, 0.5, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
    @test ComplexMixtures.getunitcell(uc_mat) == uc_mat

    # From the trajectory
    atoms = readPDB(Testing.pdbfile)
    options = Options(stride = 4, seed = 321, StableRNG = true, nthreads = 1, silent = true)
    protein = Selection(select(atoms, "protein"), nmols = 0)
    tmao = Selection(select(atoms, "resname TMAO"), natomspermol = 13)
    traj = Trajectory("$(Testing.data_dir)/NAMD/trajectory.dcd", protein, tmao)
    ComplexMixtures.opentraj!(traj)
    ComplexMixtures.firstframe!(traj)
    ComplexMixtures.nextframe!(traj)
    @test ComplexMixtures.getunitcell(traj) ==
          SVector(83.42188262939453, 84.42188262939453, 84.42188262939453)
    ComplexMixtures.closetraj!(traj)
end
