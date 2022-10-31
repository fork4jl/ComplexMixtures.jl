"""     
    mddf(trajectory::Trajectory, options::Options)

Function that computes the minimum-distance distribution function, atomic contributions, and 
KB integrals, given the `Trajectory` structure of the simulation and, optionally, parameters
given as a second argument of the `Options` type. This is the main function of the `ComplexMixtures` 
package. 

### Examples

```julia-repl
julia> trajectory = Trajectory("./trajectory.dcd",solute,solvent);

julia> results = mddf(trajectory);
```

or, to set some custom optional parameter,

```julia-repl
julia> options = Options(lastframe=1000);

julia> results = mddf(trajectory,options);
```

"""
mddf(trajectory::Trajectory) = mddf(trajectory, Options())

# Structures to dispatch on Self or Cross computations
struct Self end
struct Cross end

#=

Choose self and cross versions

In both the self and (cross) non-self cases, the number of random samples is 
n_random_samples*solvent.nmols. However, in the non-self distribution
the sampling of solvent distances is proportional to the number of solute
molecules, thus the md count has to be averaged by solute.nmols. In the
case of the self-distribution, we compute n(n-1)/2 distances, and we will
divide this by n random samples, which is the sampling of the random
distribution. Therefore, we must weight the self-distance count by dividing
it by (n-1)/2, so that we have a count proportional to n as well, leading
to the correct weight relative to the random sample. 

=#
function mddf(trajectory::Trajectory, options::Options)
    # Set random number generator
    RNG = init_random(options)
    if options.nthreads < 0
        nthreads = Threads.nthreads()
    else
        nthreads = options.nthreads
    end
    # If the solute and the solvent are the same
    if trajectory.solute.index == trajectory.solvent.index
        samples = Samples(md = (trajectory.solvent.nmols - 1) / 2, random = options.n_random_samples)
        comp_type = Self()
    # If solute and solvent are different subsets of the simulation
    else
        samples = Samples(md = trajectory.solute.nmols, random = options.n_random_samples)
        comp_type = Cross()
    end
    R = mddf_compute(comp_type, trajectory, options, samples, RNG)
    return R
end

"""    
    mddf_compute(
        comp_type::T, 
        trajectory::Trajectory,
        options::Options,
        samples::Samples,
        RNG,
    ) where T <: Union{Self,Cross}

$(INTERNAL)

# Extended help

Computes the MDDF for all frames. If `comp_type == Self()`, use the self-correlation
functions, if `comp_type == Cross()` use cross-correlation functions.

"""
function mddf_compute(
    comp_type::T, 
    trajectory::Trajectory,
    options::Options,
    samples::Samples,
    RNG,
) where {T<:Union{Self,Cross}}

    # Initializing the structure that carries all results
    R = Result(trajectory, options)

    # Data structure to be passed to mddf_frame
    framedata = FrameData(trajectory, R)

    # Print some information about this run
    options.silent || title(R, trajectory.solute, trajectory.solvent)
     
    # Initialize system for computing distances with CellListMap
    system = setup_PeriodicSystem(comp_type, trajectory, options)

    # Computing all minimum-distances
    options.silent || progress = Progress(R.nframes_read, 1)
    for iframe = 1:R.lastframe_read

        # reading coordinates of next frame
        nextframe!(trajectory)
        if iframe < options.firstframe
            continue
        end
        if iframe % options.stride != 0
            continue
        end
        mddf_frame!(comp_type, R, iframe, framedata, options, RNG, system)

        options.silent || next!(progress)
    end # frames
    closetraj(trajectory)

    # Setup the final data structure with final values averaged over the number of frames,
    # sampling, etc, and computes final distributions and integrals
    finalresults!(R, options, trajectory, samples)
    options.silent || println(bars)

    return R
end

"""
    mddf_frame_cross!(::Cross, iframe::Int, framedata::FrameData, options::Options, RNG, R::Result, system::PeriodicSystem)

$(INTERNAL)

Computes the MDDF for a single frame, modifies the data in the `R` (type `Result`) structure.

"""
function mddf_frame!(::Cross, iframe::Int, framedata::FrameData, options::Options, RNG, R::Result, system::PeriodicSystem)

    # Simplify code by assigning some shortened names
    trajectory = framedata.trajectory
    volume_frame = framedata.volume_frame
    rdf_count_random_frame = framedata.rdf_count_random_frame
    md_count_random_frame = framedata.md_count_random_frame
    dc = framedata.dc
    dmin_mol = framedata.dmin_mol
    dref_mol = framedata.dref_mol
    x_solvent_random = framedata.x_solvent_random
    lc_solvent = framedata.lc_solvent
    solute = trajectory.solute
    solvent = trajectory.solvent
    x_solute = trajectory.x_solute
    x_solvent = trajectory.x_solvent

    # Reset counters for this frame
    reset!(volume_frame)
    @. rdf_count_random_frame = 0.0
    @. md_count_random_frame = 0.0

    # Check if the cutoff is not too large considering the periodic cell size
    if R.cutoff > sides[1] / 2 || R.cutoff > sides[2] / 2 || R.cutoff > sides[3] / 2
        error("""
        in MDDF: cutoff or dbulk > periodic_dimension/2 in frame: $iframe
                 max(cutoff,dbulk) = $(R.cutoff)
                 sides read from file = $(sides)
                 If sides are zero it is likely that the PBC information is not available 
                 in the trajectory file.
        """)
    end

    volume_frame.total = sides[1] * sides[2] * sides[3]
    R.volume.total = R.volume.total + volume_frame.total

    R.density.solute = R.density.solute + (solute.nmols / volume_frame.total)
    R.density.solvent = R.density.solvent + (solvent.nmols / volume_frame.total)

    # Compute minimum distances of the molecules to the solute
    minimum_distances!(system)

    # Fraction of solvent molecules in bulk
    n_solvent_in_bulk = count(mol -> !mol.within_cutoff, list) / solute.nmols

    local n_dmin_in_bulk
    n_solvent_in_bulk = 0.0
    for isolute = 1:solute.nmols

        # We need to do this one solute molecule at a time to avoid exploding the memory
        # requirements
        x_this_solute = viewmol(isolute, x_solute, solute)

        # Compute all distances between solute and solvent atoms which are smaller than the 
        # cutoff (this is the most computationally expensive part), the distances are returned
        # in the dc structure
        cutoffdistances!(R.cutoff, x_this_solute, x_solvent, lc_solvent, box, dc)

        # For each solute molecule, update the counters (this is highly suboptimal, because
        # within updatecounters there are loops over solvent molecules, in such a way that
        # this will loop with cost nsolute*nsolvent. However, I cannot see an easy solution 
        # at this point with acceptable memory requirements
        n_dmin_in_bulk, n_dref_in_bulk = updatecounters!(R, solute, solvent, dc, dmin_mol, dref_mol)
        n_solvent_in_bulk += n_dref_in_bulk
    end
    n_solvent_in_bulk = n_solvent_in_bulk / solute.nmols

    #
    # Computing the random-solvent distribution to compute the random minimum-distance count
    #
    bulk_range = (solvent.nmols-n_dmin_in_bulk+1):solvent.nmols
    for i = 1:options.n_random_samples

        # generate random solvent box, and store it in x_solvent_random
        for j = 1:solvent.nmols
            # Choose randomly one molecule from the bulk, if there are actual bulk molecules
            if n_dmin_in_bulk != 0
                jmol = dmin_mol[random(RNG, bulk_range)].jmol
            else
                jmol = random(RNG, 1:solvent.nmols)
            end
            # Indexes of this molecule in the x_solvent array
            x_ref = viewmol(jmol, x_solvent, solvent)
            # Indexes of the random molecule in random array
            x_rnd = viewmol(j, x_solvent_random, solvent)
            # Generate new random coordinates (translation and rotation) for this molecule
            random_move!(x_ref, R.irefatom, sides, x_rnd, RNG)
        end

        # Choose randomly one solute molecule to be the solute in this sample
        i_rand_mol = random(RNG, 1:solute.nmols)
        x_this_solute = viewmol(i_rand_mol, x_solute, solute)

        # Compute all distances between solute and solvent atoms which are smaller than the 
        # cutoff (this is the most computationally expensive part), the distances are returned
        # in the dc structure
        cutoffdistances!(R.cutoff, x_this_solute, x_solvent_random, lc_solvent, box, dc)

        # Update the counters of the random distribution
        updatecounters!(R, rdf_count_random_frame, md_count_random_frame, solvent, dc, dmin_mol, dref_mol)

    end # random solvent sampling

    # Update counters with the data of this frame
    update_counters_frame!(R, rdf_count_random_frame, md_count_random_frame, volume_frame, solute, solvent, n_solvent_in_bulk)

    return nothing
end





