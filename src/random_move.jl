#
# Function that generates a new random position for a molecule
#
# the new position is returned in x, a previously allocated array
#
# x_solvent_random might be a view of the array that contains all the solvent
# molecules
#

function random_move!(x_ref :: AbstractVector{T}, 
                      irefatom :: Int64,
                      sides :: T,
                      x_new :: AbstractVector{T}) where T <: Vf3

  # To avoid boundary problems, the center of coordinates are generated in a 
  # much larger region, and wrapped aftwerwards
  scale = 100.

  # Generate random coordiantes for the center of mass
  newcm = @. -scale*sides/2 + random(Float64)*scale*sides

  # Generate random rotation angles 
  beta = (2*pi)*random(Float64)
  gamma = (2*pi)*random(Float64)
  theta = (2*pi)*random(Float64)

  # Copy the coordinates of the molecule chosen to the random-coordinates vector
  @. x_new = x_ref
  
  # Take care that this molecule is not split by periodic boundary conditions, by
  # wrapping its coordinates around its reference atom
  wrap!(x_new,sides,x_ref[irefatom])

  # Move molecule to new position
  move!(x_new,newcm,beta,gamma,theta)

  nothing
end

