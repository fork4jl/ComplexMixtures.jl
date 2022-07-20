"""

```
mddf_frame!(iframe::Int, framedata::FrameData, options::Options, RNG, R::Result)
```

Computes the MDDF for a single frame, modifies the data in the `R` (type `Result`) structure.


"""
function mddf_frame!(iframe::Int, framedata::FrameData, options::Options, RNG, R::Result)

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

    # get pbc sides in this frame
    sides = getsides(trajectory, iframe)

    # Check if the cutoff is not too large considering the periodic cell size
    if R.cutoff > sides[1] / 2.0 || R.cutoff > sides[2] / 2.0 || R.cutoff > sides[3] / 2.0
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

    # Add the box side information to the box structure, in this frame
    box = Box(sides, R.cutoff, lcell = options.lcell)

    # Compute cell list
    cl = CellList(x_solute, x_xsolvent, box)
    aux_cl = CellListMap.AuxThreaded(cl)

    list = init_list(x_solvent, voltar: indexes of solvent molecules)
    list_threaded = [ copy(list) for _ in 1:nbatches(cl) ]

    list_refatom = init_list(x_solvent, voltar: indexes of the reference atoms)
    list_threaded_refatom = [ copy(list_refatom) for _ in 1:nbatches(cl) ]

    cl = UpdateCellList!(x_solvent, x_solute, box, cl, aux_cl)

    # Compute minimum distances of the molecules to the solute
    minimum_distances!(solvent_index, list, box, cl, list_threaded = list_threaded)

    # Compute the distances within the cutoff, of the reference atoms, to the solute
    minimum_distances!(reference_index, list_refatom, box, cl, list_threaded_refatom = list_threaded)

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
        n_dmin_in_bulk, n_dref_in_bulk =
            updatecounters!(R, solute, solvent, dc, dmin_mol, dref_mol)
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
            # Choose randomly one molecule from the bulk, if there are actually bulk molecules
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

        # wrap random solvent coordinates to box, with the center at the origin
        wrap!(x_solvent_random, sides)

        # Initialize linked cells
        initcells!(x_solvent_random, box, lc_solvent)

        # Choose randomly one solute molecule to be the solute in this sample
        i_rand_mol = random(RNG, 1:solute.nmols)
        x_this_solute = viewmol(i_rand_mol, x_solute, solute)

        # Compute all distances between solute and solvent atoms which are smaller than the 
        # cutoff (this is the most computationally expensive part), the distances are returned
        # in the dc structure
        cutoffdistances!(R.cutoff, x_this_solute, x_solvent_random, lc_solvent, box, dc)

        # Update the counters of the random distribution
        updatecounters!(
            R,
            rdf_count_random_frame,
            md_count_random_frame,
            solvent,
            dc,
            dmin_mol,
            dref_mol,
        )

    end # random solvent sampling

    # Update counters with the data of this frame
    update_counters_frame!(
        R,
        rdf_count_random_frame,
        md_count_random_frame,
        volume_frame,
        solute,
        solvent,
        n_solvent_in_bulk,
    )

    nothing
end
