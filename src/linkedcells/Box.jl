#
# Structure that contains some data required to compute the linked cells
#
struct Box
  sides :: Vector{Float64}
  nc :: Vector{Int64}
  l :: Vector{Float64}
end
# Must be initialized with a cutoff
Box() = Box(zeros(3), zeros(Int64,3), zeros(3))
