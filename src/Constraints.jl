
"""
`module Constraints`

TODO: write documentation
"""
module Constraints

using JuLIP: Dofs, AbstractConstraint, AbstractAtoms,
         mat, vecs, JVecs, JVecsF, JMatF, JMat,
         set_positions!, set_cell!, stress, defm, set_defm!,
         forces, stress, unsafe_positions

import JuLIP: dofs, project!, set_dofs!, positions, gradient, energy


export FixedCell, VariableCell


function zeros_free{T}(n::Integer, x::Vector{T}, free::Vector{Int})
   z = zeros(T, n)
   z[free] = x
   return z
end

function insert_free!{T}(p::Array{T}, x::Vector{T}, free::Vector{Int})
   p[free] = x
   return p
end

# a helper function to get a valid positions array from a dof-vector
positions{TI<:Integer}(at::AbstractAtoms, ifree::AbstractVector{TI}, dofs::Dofs) =
      insert_free!(positions(at) |> mat, dofs, ifree) |> vecs


# ========================================================================
#          FIXED CELL IMPLEMENTATION
# ========================================================================

"""
`FixedCell`: no constraints are placed on the motion of atoms, but the
cell shape is fixed

Constructor:
```julia
FixedCell(at::AbstractAtoms; free=..., clamp=..., mask=...)
```
Set at most one of the kwargs:
* no kwarg: all atoms are free
* `free` : list of free atom indices (not dof indices)
* `clamp` : list of clamped atom indices (not dof indices)
* `mask` : 3 x N Bool array to specify individual coordinates to be clamped
"""
type FixedCell <: AbstractConstraint
   ifree::Vector{Int}
end

function analyze_mask(at, free, clamp, mask)
   if length(find((free != nothing, clamp != nothing, mask != nothing))) > 1
      error("FixedCell: only one of `free`, `clamp`, `mask` may be provided")
   elseif all( (free == nothing, clamp == nothing, mask == nothing) )
      # in this case (default) all atoms are free
      return collect(1:3*length(at))
   end
   # determine free dof indices
   Nat = length(at)
   if clamp != nothing
      # revert to setting free
      free = setdiff(1:Nat, clamp)
   end
   if free != nothing
      # revert to setting mask
      mask = Matrix{Bool}(3, Nat)
      fill!(mask, false)
      mask[:, free] = true
   end
   return mask[:]
end

FixedCell(at::AbstractAtoms; free=nothing, clamp=nothing, mask=nothing) =
   FixedCell(analyze_mask(at, free, clamp, mask))

# careful here: if Julia ever makes indexing a view, then this will be bad!
dofs(at::AbstractAtoms, cons::FixedCell) = mat(unsafe_positions(at))[cons.ifree]

set_dofs!(at::AbstractAtoms, cons::FixedCell, x::Dofs) =
      set_positions!(at, positions(at, cons.ifree, x))

project!(at::AbstractAtoms, cons::FixedCell) = at

# TODO: this is a temporaruy hack, and I think we need to
#       figure out how to do this for more general constraints
#       maybe not too terrible
project!(cons::FixedCell, A::SparseMatrixCSC) = A[cons.ifree, cons.ifree]

gradient(at::AbstractAtoms, cons::FixedCell) =
               scale!(mat(forces(at))[cons.ifree], -1.0)

energy(at::AbstractAtoms, cons::FixedCell) = energy(at)


# ========================================================================
#          VARIABLE CELL IMPLEMENTATION
# ========================================================================

"""
`VariableCell`: both atom positions and cell shape are free;

**WARNING:** before manipulating the dof-vectors returned by a `VariableCell`
constraint, read *meaning of dofs* instructions at bottom of help text!

Constructor:
```julia
VariableCell(at::AbstractAtoms; free=..., clamp=..., mask=..., fixvolume=false)
```
Set at most one of the kwargs:
* no kwarg: all atoms are free
* `free` : list of free atom indices (not dof indices)
* `clamp` : list of clamped atom indices (not dof indices)
* `mask` : 3 x N Bool array to specify individual coordinates to be clamped

### Meaning of dofs

On call to the constructor, `VariableCell` stored positions and deformation
`X0, F0`, dofs are understood *relative* to this "initial configuration".

`dofs(at, cons::VariableCell)` returns a vector that represents a pair
`(U, F1)` of a displacement and a deformation matrix. These are to be understood
*relative* to the reference `X0, F0` stored in `cons` as follows:
* `F = F1`   (the cell is then `F'`)
* `X = [F1 * (F0 \ x0) + u  for (x0, u) in zip(X0, U)]`

One aspect of this definition is that clamped atom positions still change via
`F`.
"""
type VariableCell <: AbstractConstraint
   ifree::Vector{Int}
   X0::JVecsF
   F0::JMatF
   pressure::Float64
   fixvolume::Bool
   volume::Float64    # this is meaningless if `fixvolume == false`
end


function VariableCell(at::AbstractAtoms;
               free=nothing, clamp=nothing, mask=nothing,
               pressure = 0.0, fixvolume=false)
   if pressure != 0.0 && fixvolume
      warning("the pressure setting will be ignores when `fixvolume==true`")
   end
   return VariableCell( analyze_mask(at, free, clamp, mask),
                        positions(at), defm(at),
                        pressure, fixvolume, det(defm(at)) )
end

# reverse map:
#   F -> F
#   U[n] = X[n] - A * X0[n]

function dofs(at::AbstractAtoms, cons::VariableCell)
   X = unsafe_positions(at)
   F = defm(at)
   A = F * inv(cons.F0)
   U = [x - A * x0 for (x,x0) in zip(X, cons.X0)]
   return [mat(U)[cons.ifree]; Matrix(F)[:]]
end


posdofs(x) = x[1:end-9]
celldofs(x) = x[end-8:end]

function set_dofs!(at::AbstractAtoms, cons::VariableCell, x::Dofs)
   F = JMatF(celldofs(x))
   A = F * inv(cons.F0)
   X = [A * x0 for x0 in cons.X0]
   mat(X)[cons.ifree] += posdofs(x)
   set_positions!(at, X)
   set_defm!(at, F)
   return at
end

# for a variation x^t_i = (F+tU) F_0^{-1} x^0_i + u_i + t v_i
#   we get
# dE/dt |_{t=0} = U : (S F_0^{-T}) - <frc, v>
#
# this is nice because there is no contribution from the stress to
# the positions component of the gradient

vol(at::AbstractAtoms) = det(defm(at))
vol_d(at::AbstractAtoms) = vol(at) * inv(defm(at))'
# function vol_dd(at::AbstractAtoms)
#    hdetI = zeros(3,3,3,3)
#    h = 0.1
#    for i = 1:3, j = 1:3
#       Ih = eye(3); Ih[i,j] += h
#       hdetI[:,:,i,j] = (ddet(Ih) - ddetI) / h
#    end
#    round(Int, reshape(hdetI, 9, 9))
# end

function gradient(at::AbstractAtoms, cons::VariableCell)
   G = scale!(forces(at), -1.0)      # neg. forces
   S = stress(at) * inv(cons.F0)'        # ∂E / ∂F (Piola-Kirchhoff stress)
   S -= cons.pressure * vol_d(at)     # applied stress
   return [ mat(G)[cons.ifree]; Array(S)[:] ]
end

function energy(at::AbstractAtoms, cons::VariableCell)
   return energy(at) - cons.pressure * det(defm(at))
end


# TODO: fix this once we implement the volume constraint ??????
project!(at::AbstractAtoms, cons::VariableCell) = at

# TODO: fix the abstraction for projecting a preconditioner;
#       this will actually need to do quite a bit more in the future
# project!(cons::FixedCell, A::SparseMatrixCSC) = A[cons.ifree, cons.ifree]


end # module
