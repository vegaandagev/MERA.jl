# The most important types of the package, GenericMERA and Layer, on which all specific MERA
# implementations (binary, ternary, ...) are built. Methods and functions that can be
# implemented on this level of abstraction, without having to know the details of the
# specific MERA type.
# To be included in MERA.jl.

"""
Layer is an abstract supertype of concrete types such as BinaryLayer. A typical Layer is a
collection of tensors, the orders and shapes of which depend on the type.
"""
abstract type Layer end

"""
A GenericMERA is a collection of Layers. The type of these layers then determines whether
the MERA is binary, ternary, etc.

A few notes on conventions and terminology:
- The physical indices of the MERA are at the "bottom", the scale invariant part at the
"top".
- The counting of layers starts from the bottom, so the layer with physical indices is layer
#1. The last layer is the scale invariant one, that then repeats upwards to infinity.
- Each layer is thought of as a linear map from its top, or input space to its bottom, or
output space.
"""
struct GenericMERA{T}
    layers::Vector{T}
    stored_densitymatrices::Vector
    stored_operators::Dict{Any, Vector}
    # Prevent the creation of GenericMERA{T} objects when T is not a subtype of Layer.
    function GenericMERA{T}(layers) where T <: Layer
        num_layers = length(layers)
        stored_densitymatrices = Vector{Any}(repeat([nothing], num_layers))
        stored_operators = Dict{Any, Vector}()
        new(collect(layers), stored_densitymatrices, stored_operators)
    end
end

# # # Basic utility functions

"""
Return the type of the layers of `m`.
"""
layertype(m::T) where {T <: GenericMERA} = layertype(T)
layertype(::Type{GenericMERA{T}}) where {T <: Layer} = T

Base.eltype(m::GenericMERA) = reduce(promote_type, map(eltype, m.layers))

"""
The ratio by which the number of sites changes when go down by a layer.
"""
scalefactor(::Type{GenericMERA{T}}) where T = scalefactor(T)

"""
Each MERA has a stable width causal cone, that depends on the type of layers the MERA has.
Return that width.
"""
causal_cone_width(::Type{GenericMERA{T}}) where T <: Layer = causal_cone_width(T)

"""
Return the number of transition layers, i.e. layers below the scale invariant one, in the
MERA.
"""
num_translayers(m::GenericMERA) = length(m.layers)-1

"""
Return the layer at the given depth. 1 is the lowest layer, i.e. the one with physical
indices.
"""
get_layer(m::GenericMERA, depth) = (depth > num_translayers(m) ?
                                    m.layers[end] : m.layers[depth])

"""
Set, in-place, one of the layers of the MERA to a new, given value. If check_invar=true,
check that the indices match afterwards.
"""
function set_layer!(m::GenericMERA, layer, depth; check_invar=true)
    depth > num_translayers(m) ? (m.layers[end] = layer) : (m.layers[depth] = layer)
    m = reset_storage!(m, depth)
    check_invar && space_invar(m)
    return m
end

"""
Add one more transition layer at the top of the MERA, by taking the lowest of the scale
invariant one and releasing it to vary independently.
"""
function release_transitionlayer!(m::GenericMERA)
    layer = get_layer(m, Inf)
    layer = copy(layer)
    push!(m.layers, layer)
    density_matrix = m.stored_densitymatrices[end]
    push!(m.stored_densitymatrices, density_matrix)
    for (k, v) in m.stored_operators
        operator = v[end]
        push!(v, operator)
    end
    return m
end

"""
Given a MERA and a depth, return the vector space of the downwards-pointing (towards the
physical level) indices of the layer at that depth.
"""
outputspace(m::GenericMERA, depth) = outputspace(get_layer(m, depth))

"""
Given a MERA and a depth, return the vector space of the upwards-pointing (towards scale
invariance) indices of the layer at that depth.
"""
inputspace(m::GenericMERA, depth) = inputspace(get_layer(m, depth))

"""
Compute the von Neumann entropy of a density matrix `rho`.
"""
function densitymatrix_entropy(rho)
    eigs = eigh(rho)[1]
    eigs = real.(diag(convert(Array, eigs)))
    if sum(abs.(eigs[eigs .<= 0.])) > 1e-13
        warn("Significant negative eigenvalues for a density matrix: $eigs")
    end
    eigs = eigs[eigs .> 0.]
    S = -dot(eigs, log.(eigs))
    return S
end

densitymatrix_entropies(m::GenericMERA) = map(densitymatrix_entropy, densitymatrices(m))

# Function that returns its first argument. Used as a default value for the energy
# normalization function.
noop_firstarg(args...) = args[1]

# # # Storage of density matrices and ascended operators

# The storage format for density matrices and operators is a little different:
# For density matrices we always store a Vector of the same length as there are layers. If
# a density matrix is not in store, `nothing` is kept as the corresponding element.
# For operators, m.stored_operators is a dictionary with operators as keys, and each
# element is a Vector that lists the ascended versions of that operator, starting from the
# physical one, which is nothing but the original operator. No place-holder `nothing`s are
# stored, the Vector ends when storage ends.
# This difference is because density matrices are naturally generated from the top, and
# there will never be more than the number of layers of them. Operators are generated from
# the bottom, and they may go arbitrarily high in the MERA (into the scale invariant part).

"""
Reset stored density matrices and ascended operators, so that they will be recomputed when
they are needed. By default all are reset. If the optional argument `depth` is given, only
ones invalidated by changing the layer at `depth` are removed.
"""
function reset_storage!(m::GenericMERA, depth)
    depth = Int(min(num_translayers(m)+1, depth))
    m.stored_densitymatrices[1:depth] .= nothing
    for (k, v) in m.stored_operators
        last_index = min(depth, length(v))
        m.stored_operators[k] = v[1:last_index]
    end
    return m
end

function reset_storage!(m::GenericMERA)
    m.stored_densitymatrices[:] .= nothing
    reset_operator_storage!(m)
    return m
end

"""
Return whether the density matrix at given depth is already in store.
"""
function has_densitymatrix_stored(m::GenericMERA, depth)
    depth = Int(min(num_translayers(m)+1, depth))
    rho = m.stored_densitymatrices[depth]
    return rho !== nothing
end

"""
Return the density matrix at given depth, assuming it's in store.
"""
function get_stored_densitymatrix(m::GenericMERA, depth)
    depth = Int(min(num_translayers(m)+1, depth))
    rho = m.stored_densitymatrices[depth]
    if rho === nothing
        msg = "Density matrix at depth $(depth) not in storage."
        throw(ArgumentError(msg))
    end
    return rho
end

"""
Store the density matrix at given depth.
"""
function set_stored_densitymatrix!(m::GenericMERA, density_matrix, depth)
    m.stored_densitymatrices[depth] = density_matrix
    return m
end

"""
Return the stored ascended versions of `op`. Initialize storage for `op` if necessary.
"""
function operator_storage(m::GenericMERA, op)
    if !(op in keys(m.stored_operators))
        m.stored_operators[op] = Vector{Any}([op])
    end
    return m.stored_operators[op]
end

"""
Return whether the operator `op` ascended to `depth` is already in store.
"""
function has_operator_stored(m::GenericMERA, op, depth)
    storage = operator_storage(m, op)
    return length(storage) >= depth
end

"""
Return the operator `op` ascended to a given depth, assuming it's in store.
"""
function get_stored_operator(m::GenericMERA, op, depth)
    storage = operator_storage(m, op)
    return storage[depth]
end

"""
Store `opasc`, the operator `op` ascended to a given depth.
"""
function set_stored_operator!(m::GenericMERA, opasc, op, depth)
    storage = operator_storage(m, op)
    if length(storage) < depth-1
        msg = "Can't store an ascended operator if the lower versions of it aren't in storage already."
        throw(ArgumentError(msg))
    elseif length(storage) == depth-1
        push!(storage, opasc)
    else
        storage[depth] = opasc
    end
    return m
end

"""
Reset storage for a given operator.
"""
function reset_operator_storage!(m::GenericMERA, op)
    delete!(m.stored_operators, op)
    return m
end

"""
Reset storage for all operators.
"""
function reset_operator_storage!(m::GenericMERA)
    ops = keys(m.stored_operators)
    for op in ops
        reset_operator_storage!(m, op)
    end
    return m
end

# # # Generating random MERAs

"""
Replace the layer at the given depth with a random one. Additional keyword arguments are
passed to the function that generates the random layer, the details of which depend on the
specific layer type (binary, ternary, ...).
"""
function randomizelayer!(m::GenericMERA{T}, depth; kwargs...) where T
    Vin = inputspace(m, depth)
    Vout = outputspace(m, depth)
    layer = randomlayer(T, Vin, Vout; kwargs...)
    set_layer!(m, layer, depth)
    return m
end

"""
Generate a random MERA of type `T`, with `V` as the vector space of all layers, and with
`num_layers` as the number of different layers (including the scale invariant one).
Additional keyword arguments are passed on to the function that generates a single random
layer.
"""
function random_MERA(::Type{T}, V, num_layers; kwargs...) where T <: GenericMERA
    Vs = repeat([V], num_layers)
    return random_MERA(T, Vs; kwargs...)
end

"""
Generate a random MERA of type `T`, with `Vs` as the vector spaces of the various layers.
Number of layers will be the length of `Vs`, the `Vs[1]` will be the physical index space,
and `Vs[end]` will be the one at the scale invariant layer.  Additional keyword arguments
are passed on to the function that generates a single random layer.
"""
function random_MERA(::Type{T}, Vs; kwargs...) where T <: GenericMERA
    num_layers = length(Vs)
    layers = []
    for i in 1:num_layers
        V = Vs[i]
        Vnext = (i < num_layers ? Vs[i+1] : V)
        layer = randomlayer(layertype(T), Vnext, V; kwargs...)
        push!(layers, layer)
    end
    m = T(layers)
    return m
end

"""
Return a MERA layer with random tensors. The first argument is the Layer type, and the
second and third are the input and output spaces. May take further keyword arguments
depending on the Layer type. Each subtype of Layer should have its own method for this
function.
"""
function randomlayer end

"""
Expand the bond dimension of the MERA at the given depth. `depth=1` is the first virtual
level, just above the first layer of the MERA, and the numbering grows from there. The new
bond dimension is given by `newdims`, which for a non-symmetric MERA is just a number, and
for a symmetric MERA is a dictionary of {irrep => block dimension}. Not all irreps for a
bond need to be listed, the ones left out are left untouched.

The expansion is done by padding tensors with zeros. Note that this breaks isometricity of
the individual tensors. This is however of no consequence, since the MERA as a state remains
exactly the same. A round of optimization on the MERA will restore isometricity of each
tensor.
"""
function expand_bonddim!(m::GenericMERA, depth, newdims)
    V = inputspace(m, depth)
    V = expand_vectorspace(V, newdims)

    layer = get_layer(m, depth)
    layer = expand_inputspace(layer, V)
    set_layer!(m, layer, depth; check_invar=false)

    next_layer = get_layer(m, depth+1)
    next_layer = expand_outputspace(next_layer, V)
    if depth == num_translayers(m)
        # next_layer is the scale invariant part, so we need to change its top
        # index too since we changed the bottom.
        next_layer = expand_inputspace(next_layer, V)
    elseif depth > num_translayers(m)
            msg = "expand_bonddim! called with too large depth. To change the scale invariant bond dimension, use depth=num_translayers(m)."
            throw(ArgumentError(msg))
    end
    set_layer!(m, next_layer, depth+1; check_invar=true)
end

"""
Return a new layer where the tensors have been padded with zeros as necessary to change the
input space. The first argument is the layer, the second one is the new input space. Each
subtype of Layer should have its own method for this function.
"""
function expand_inputspace end

"""
Return a new layer where the tensors have been padded with zeros as necessary to change the
output space. The first argument is the layer, the second one is the new output space. Each
subtype of Layer should have its own method for this function.
"""
function expand_outputspace end

"""
Given a MERA which may possibly be built of symmetry preserving TensorMaps, return another
MERA that has the symmetry structure stripped from it, and all tensors are dense.
"""
remove_symmetry(m::T) where T <: GenericMERA = T(map(remove_symmetry, m.layers))

# # # Pseudo(de)serialization
# "Pseudo(de)serialization" refers to breaking the MERA down into types in Julia Base, and
# constructing it back. This can be used for storing MERAs on disk.
# TODO Once JLD or JLD2 works properly we should be able to get rid of this.
#
# Note that pseudoserialization discards stored_densitymatrices and stored_operators, which
# then need to be recomputed after deserialization.

"""
Return a tuple of objects that can be used to reconstruct a given MERA, and that are all of
Julia base types.
"""
pseudoserialize(m::T) where T <: GenericMERA = (repr(T), map(pseudoserialize, m.layers))

"""
Reconstruct a MERA given the output of `pseudoserialize`.
"""
depseudoserialize(::Type{T}, args) where T <: GenericMERA = T([depseudoserialize(d...)
                                                               for d in args])

# Implementations for pseudoserialize(l::T) and depseudoserialize(::Type{T}, args...) should
# be written for each T <: Layer. They can make use of the (de)pseudoserialize methods for
# TensorMaps from `tensortools.jl`.

# # # Invariants

"""
Check that the indices of the various tensors in a given MERA are compatible with each
other. If not, throw an ArgumentError. If yes, return true. This relies on two checks,
`space_invar_intralayer` for checking indices within a layer and `space_invar_interlayer`
for checking indices between layers. These should be implemented for each subtype of Layer.
"""
function space_invar(m::GenericMERA{T}) where T
    layer = get_layer(m, 1)
    # We go to num_translayers(m)+2, to check that the scale invariant layer is consistent
    # with itself.
    for i in 2:(num_translayers(m)+2)
        next_layer = get_layer(m, i)
        if applicable(space_invar_intralayer, layer)
            if !space_invar_intralayer(layer)
                errmsg = "Mismatching bonds in MERA within layer $(i-1)."
                throw(ArgumentError(errmsg))
            end
        else
            msg = "space_invar_intralayer has no method for type $(T). We recommend writing one, to enable checking for space mismatches when assigning tensors."
            @warn(msg)
        end

        if applicable(space_invar_interlayer, layer, next_layer)
            if !space_invar_interlayer(layer, next_layer)
                errmsg = "Mismatching bonds in MERA between layers $(i-1) and $i."
                throw(ArgumentError(errmsg))
            end
        else
            msg = "space_invar_interlayer has no method for type $(T). We recommend writing one, to enable checking for space mismatches when assigning tensors."
            @warn(msg)
        end
        layer = next_layer
    end
    return true
end

"""
Given a Layer, return true if the indices within the layer are compatible with each other,
false otherwise.

This method should be implemented separately for each subtype of Layer.
"""
function space_invar_intralayer end

"""
Given two Layers, return true if the indices between them are compatible with each other,
false otherwise. The first argument is the layer below the second one.

This method should be implemented separately for each subtype of Layer.
"""
function space_invar_interlayer end

# # # Scaling functions

"""
Ascend the operator `op`, that lives on the layer `startscale`, through the MERA to the
layer `endscale`. Living "on" a layer means living on the indices right below it, so
`startscale=1` (the default) refers to the physical indices, and
`endscale=num_translayers(m)+1` (the default) to the indices just below the first scale
invariant layer.
"""
function ascend(op, m::GenericMERA; endscale=num_translayers(m)+1, startscale=1)
    if endscale < startscale
        throw(ArgumentError("endscale < startscale"))
    elseif endscale > startscale
        op = ascend(op, m; endscale=endscale-1, startscale=startscale)
        layer = get_layer(m, endscale-1)
        op = ascend(op, layer)
    end
    return op
end

"""
Descend the operator `op`, that lives on the layer `startscale`, through the MERA to the
layer `endscale`. Living "on" a layer means living on the indices right below it, so
`endscale=1` (the default) refers to the physical indices, and
`startscale=num_translayers(m)+1` (the default) to the indices just below the first scale
invariant layer.
"""
function descend(op, m::GenericMERA; endscale=1, startscale=num_translayers(m)+1)
    if endscale > startscale
        throw(ArgumentError("endscale > startscale"))
    elseif endscale < startscale
        op = descend(op, m; endscale=endscale+1, startscale=startscale)
        layer = get_layer(m, endscale)
        op = descend(op, layer)
    end
    return op
end

"""
Find the fixed point density matrix of the scale invariant part of the MERA.
"""
function fixedpoint_densitymatrix(m::GenericMERA)
    f(x) = descend(x, m; endscale=num_translayers(m)+1, startscale=num_translayers(m)+2)
    x0 = thermal_densitymatrix(m, Inf)
    vals, vecs, info = eigsolve(f, x0)
    rho = vecs[1]
    # rho is Hermitian only up to a phase. Divide out that phase.
    rho /= tr(rho)
    return rho
end

"""
Return the thermal density matrix for the indices right below the layer at `depth`. Used as
an initial guess for the fixed-point density matrix.
"""
function thermal_densitymatrix(m::GenericMERA, depth)
    V = inputspace(m, Inf)
    width = causal_cone_width(typeof(m))
    eye = id(V)
    rho = ⊗(repeat([eye], width)...)
    return rho
end

"""
Return the density matrix right below the layer at `depth`.

This method stores every density matrix in memory as it computes them, and fetches them from
there if the same one is requested again.
"""
function densitymatrix(m::GenericMERA, depth)
    if has_densitymatrix_stored(m, depth)
        rho = get_stored_densitymatrix(m, depth)
    else
        # If we don't find rho in storage, generate it.
        if depth > num_translayers(m)
            rho = fixedpoint_densitymatrix(m)
        else
            rho_above = densitymatrix(m, depth+1)
            rho = descend(rho_above, m; endscale=depth, startscale=depth+1)
        end
        # Store this density matrix for future use.
        set_stored_densitymatrix!(m, rho, depth)
    end
    return rho
end

"""
Return the density matrices starting for the layers from `lowest_depth` upwards up to and
including the scale invariant one.
"""
function densitymatrices(m::GenericMERA, lowest_depth=1)
    rhos = [densitymatrix(m, depth) for depth in lowest_depth:num_translayers(m)+1]
    return rhos
end

"""
Return the operator `op` ascended from the physical level to `depth`. The benefit of using
this over `ascend(m, op; startscale=1, endscale=depth)` is that this one stores the result
in memory and fetches it from there if them same operator is requested again.
"""
function ascended_operator(m::GenericMERA, op, depth)
    # Note that if depth=1, has_operator_stored always returns true, as it initializes
    # storage for this operator.
    if has_operator_stored(m, op, depth)
        opasc = get_stored_operator(m, op, depth)
    else
        op_below = ascended_operator(m, op, depth-1)
        opasc = ascend(op_below, m; endscale=depth, startscale=depth-1)
        # Store this density matrix for future use.
        set_stored_operator!(m, opasc, op, depth)
    end
    return opasc
end

# TODO Understand better the issue of exponential weights vs no weights. As I see it now, no
# weights is the correct thing when evaluating a gradient. Because the ascended h soon
# becomes the dominant eigenvector of the ascending superoperator (the identity), the
# contributions after a few layers are orthogonal to the optimization manifold, and thus the
# gradient vector is unchanged by them. The exponential weights are just an ad hoc trick for
# E-V. If this understanding is correct, change the structure of how this is computed, so
# that for instance pars[:havg_eps] actually has an effect when evaluating a gradient.
# Probably also change the arguments that this function takes, and update the docstring.
"""
TODO This docstring is out-of-date.
Return the sum of the ascended versions of `op` in the scale invariant part of the MERA,
normalized by the number of tensors in each layer. That is
``sum_{i=1}^Inf ascended_operator(m, op, num_translayers + i) / scalefactor^(i-1).``
This infinite sum is of course not summed in total. Instead, we approximate by assuming that
from some depth `l` onwards all the ascended operators are the same. The tolerance for error
in this approximation is set by the argument eps.  This function uses `ascended_operator` to
get the operators at each layer, which means that it makes use of the cache.
"""
function ascended_operator_avg(m::GenericMERA, op, pars, weight=:none)
    ops = Any[]
    opavg = nothing
    nt = num_translayers(m)
    sf = scalefactor(typeof(m))
    series_sum = sf/(sf-1)  # This is the value of the series sum_{i=0}^Inf 1/sf^i.
    # TODO This could be optimized to avoid resumming all the terms every time. Hardly
    # urgent though, given how subleading this whole thing is in bond dimension.
    for l in 1:pars[:havg_depth]
        old_opavg = opavg
        op_l = ascended_operator(m, op, nt+l)
        push!(ops, op_l)
        if weight === :exponential
            # Normalization factors for each term. The last one gets multiplied by
            # series_sum, since the assumption is that from l onwards all the ascended
            # operators are the same.
            normalizations = [one(eltype(m))/sf^(j-1) for j in 1:l]
            normalizations[end] *= series_sum
        elseif weight === :none
            normalizations = [one(eltype(m)) for j in 1:l]
        else
            throw(ArgumentError("Unknown value for weight: $weight"))
        end
        opavg = sum(op*n for (op, n) in zip(ops, normalizations))
        change = old_opavg === nothing ? 1 : norm(opavg - old_opavg)/norm(opavg)
        change < pars[:havg_eps] && break
    end
    return opavg
end

# # # Extracting CFT data

"""
Diagonalize the scale invariant ascending superoperator to compute the scaling dimensions of
the underlying CFT. The return value is a dictionary, the keys of which are symmetry sectors
for a possible internal symmetry of the MERA (Trivial() if there is no internal symmetry),
and values are scaling dimensions in this symmetry sector.
"""
function scalingdimensions(m::GenericMERA; howmany=20)
    V = inputspace(m, Inf)
    chi = dim(V)
    width = causal_cone_width(typeof(m))
    # Don't even try to get more than half of the eigenvalues. Its too expensive, and they
    # are garbage anyway.
    maxmany = Int(ceil(chi^width/2))
    howmany = min(maxmany, howmany)
    # Define a function that takes an operator and ascends it once through the scale
    # invariant layer.
    nm = num_translayers(m)
    f(x) = ascend(x, m; endscale=nm+2, startscale=nm+1)
    # Find out which symmetry sectors we should do the diagonalization in.
    interlayer_space = reduce(⊗, repeat([V], width))
    sects = sectors(fuse(interlayer_space))
    scaldim_dict = Dict()
    for irrep in sects
        # Diagonalize in each irrep sector.
        x0 = scalingoperator_initialguess(m, interlayer_space, irrep)
        S, U, info = eigsolve(f, x0, howmany, :LM)
        # sfact is the ratio by which the number of sites changes at each coarse-graining.
        sfact = scalefactor(typeof(m))
        scaldims = sort(-log.(sfact, abs.(real(S))))
        scaldim_dict[irrep] = scaldims
    end
    return scaldim_dict
end

"""
Return an initial guess to be used in the iterative eigensolver that solves for scaling
operators.
"""
function scalingoperator_initialguess(m::GenericMERA, interlayer_space, irrep)
    typ = eltype(m)
    inspace = interlayer_space
    outspace = interlayer_space
    # If this is a non-trivial irrep sector, expand the input space with a dummy leg.
    irrep !== Trivial() && (inspace = inspace ⊗ spacetype(inspace)(irrep => 1))
    # The initial guess for the eigenvalue search. Also defines the type for
    # eigenvectors.
    x0 = TensorMap(randn, typ, outspace ← inspace)
    return x0
end

# # # Evaluation

"""
Return the expecation value of operator `op` for this MERA. The layer on which `op` lives is
set by `opscale`, which by default is the physical one (`opscale=1`). `evalscale` can be
used to set whether the operator is ascended through the network or the density matrix is
descended.
"""
function expect(op, m::GenericMERA; opscale=1, evalscale=1)
    rho = densitymatrix(m, evalscale)
    op = ascended_operator(m, op, evalscale)
    # If the operator is defined on a smaller support (number of sites) than rho, expand it.
    op = expand_support(op, support(rho))
    value = tr(rho * op)
    if abs(imag(value)/norm(op)) > 1e-13
        @warn("Non-real expectation value: $value")
    end
    value = real(value)
    return value
end


# # # Optimization

function minimize_expectation!(m, h, pars; vary_disentanglers=true, kwargs...)
    # If pars[:isometries_only_iters] is set, but the optimization on the whole is supposed
    # to vary_disentanglers too, then first run a pre-optimization without touching the
    # disentanglers, with pars[:isometries_only_iters] as the maximum iteration count,
    # before moving on to the main optimization with all tensors varying.
    if vary_disentanglers && pars[:isometries_only_iters] > 0
        temp_pars = deepcopy(pars)
        temp_pars[:maxiter] = pars[:isometries_only_iters]
        m = minimize_expectation!(m, h, temp_pars; vary_disentanglers=false, kwargs...)
    end
    # We'll be calling many functions (;vary_disentanglers=vary_disentanglers, kwargs...),
    # so make that easier by having :vary_disentanglers in kwargs.
    kwargs = Dict{Symbol, Any}(kwargs...)
    kwargs[:vary_disentanglers] = vary_disentanglers

    method = pars[:method]
    if method in (:cg, :conjugategradient, :gd, :gradientdescent, :lbfgs)
        return minimize_expectation_grad!(m, h, pars; kwargs...)
    elseif method == :ev || method == :evenblyvidal
        return minimize_expectation_ev!(m, h, pars; kwargs...)
    else
        for p in 0:100
            method_candidate1 = Symbol("ev$(p)lbfgs$(100-p)")
            method_candidate2 = Symbol("lbfgs$(p)ev$(100-p)")
            if method == method_candidate1
                temp_pars1 = deepcopy(pars)
                temp_pars2 = deepcopy(pars)
                temp_pars1[:method] = :ev
                temp_pars1[:maxiter] = Int(round(pars[:maxiter]*p/100))
                temp_pars2[:method] = :lbfgs
                temp_pars2[:maxiter] = Int(round(pars[:maxiter]*(100-p)/100))
                m = minimize_expectation_ev!(m, h, temp_pars1; kwargs...)
                return minimize_expectation_grad!(m, h, temp_pars2; kwargs...)
            elseif method == method_candidate2
                temp_pars1 = deepcopy(pars)
                temp_pars2 = deepcopy(pars)
                temp_pars1[:method] = :lbfgs
                temp_pars1[:maxiter] = Int(round(pars[:maxiter]*p/100))
                temp_pars2[:method] = :ev
                temp_pars2[:maxiter] = Int(round(pars[:maxiter]*(100-p)/100))
                m = minimize_expectation_grad!(m, h, temp_pars1; kwargs...)
                return minimize_expectation_ev!(m, h, temp_pars2; kwargs...)
            end
        end
        msg = "Unknown optimization method $(method)."
        throw(ArgumentError(msg))
    end
end

"""
Optimize the MERA `m` to minimize the expectation value of `h` using the Evenbly-Vidal
method.

The optimization proceeds by looping over layers and optimizing each in turn, starting from
the bottom, and repeating this until convergence is reached.

The keyword argument `lowest_depth` sets the lowest layer in the MERA that the optimization
is allowed to change, by default `lowest=1` so all layers are optimized. They keyword
argument `normalization` is a function that takes in the expectation value of `h` and
returns another number that is the actual quantity of interest (because `h` may for instance
be the Hamiltonian but with a changed normalization).  It is only used for printing log
messages, and doesn't affect the optimization.

The argument `pars` is a dictionary with symbols as keys, that lists values for different
parameters for how to do the optimization. They all need to be specified by the user, and
have no default values. The different parameters are:
    :miniter, a minimum number of iterations to do over the layers before returning. The
     first half of the minimum number of iterations will be spent optimizing only isometric
     tensors, leaving the disentanglers untouched.
    :maxiter, the maximum number of iterations to do over the layers before returning.
    :densitymatrix_delta, the convergence threshold. Convergence is measured as changes in
     the reduced density matrices of the MERA. Once the maximum by which any of them changed
     over consecutive iterations falls below pars[:densitymatrix_delta], the optimization
     terminates. Change is measured as Frobenius norm of the difference. Note that this is
     much more demanding than convergence in just the expectation value.
    :havg_depth, how deep into the scale invariant layer to go when computing the ascended
     version of `h` to use for optimizing the scale invariant layer. Should in principle be
     infinite, but the error goes down exponentially, so in practice 10 is often plenty.
    Other parameters may be required depending on the type of MERA. See documentation for
    the different Layer types. Typical parameters are for instance how many times to iterate
    optimizing individual tensors.
"""
function minimize_expectation_ev!(m, h, pars; lowest_depth=1, normalization=noop_firstarg,
                                  vary_disentanglers=true)
    nt = num_translayers(m)
    expectation = normalization(expect(h, m))
    rhos = densitymatrices(m)
    rhos_maxchange = Inf
    gradnorm = Inf
    counter = 0
    if pars[:verbosity] >= 2
        @info(@sprintf("E-V: initializing with f = %.12f,", expectation))
    end
    while gradnorm > pars[:gradient_delta] && counter < pars[:maxiter]
        counter += 1
        old_rhos = rhos
        old_expectation = expectation
        gradnorm_sq = 0

        for l in lowest_depth:nt
            rho = densitymatrix(m, l+1)
            hl = ascended_operator(m, h, l)
            layer = get_layer(m, l)
            layer, gradnorm_layer = minimize_expectation_ev(hl, layer, rho, pars;
                                                            vary_disentanglers=vary_disentanglers)
            gradnorm_sq += gradnorm_layer^2
            set_layer!(m, layer, l)
        end

        # Special case of the translation invariant layer.
        havg = ascended_operator_avg(m, h, pars, :exponential)
        layer = get_layer(m, Inf)
        rho = densitymatrix(m, Inf)
        layer, gradnorm_layer = minimize_expectation_ev(havg, layer, rho, pars;
                                                        vary_disentanglers=vary_disentanglers)
        gradnorm_sq += gradnorm_layer^2
        set_layer!(m, layer, Inf)

        gradnorm = normalization(sqrt(gradnorm_sq), Val(:gradient))
        expectation = expect(h, m)
        expectation = normalization(expectation)
        rhos = densitymatrices(m)
        if old_rhos !== nothing
            rho_diffs = [norm(r - ro) for (r, ro) in zip(rhos, old_rhos)]
            rhos_maxchange = maximum(rho_diffs)
        end
        if pars[:verbosity] >= 2
            @info(@sprintf("E-V: iter %4d: f = %.12f, ‖∇f‖ = %.4e, max‖Δρ‖ = %.4e",
                           counter, expectation, gradnorm, rhos_maxchange))
        end
    end
    if pars[:verbosity] > 0
        if gradnorm <= pars[:gradient_delta]
            @info(@sprintf("E-V: converged after %d iterations: f = %.12f, ‖∇f‖ = %.4e, max‖Δρ‖ = %.4e",
                           counter, expectation, gradnorm, rhos_maxchange))
        else
            @warn(@sprintf("E-V: not converged to requested tol: f = %.12f, ‖∇f‖ = %.4e, max‖Δρ‖ = %.4e",
                           expectation, gradnorm, rhos_maxchange))
        end
    end
    return m
end

# # # Gradient optimization

function istangent(m::T, mtan::T) where T <: GenericMERA
    n = max(num_translayers(m), num_translayers(mtan)) + 1
    return all([istangent(get_layer(m, i), get_layer(mtan, i)) for i in 1:n])
end

function tensorwise_scale(m::T, alpha) where T <: GenericMERA
    return T([tensorwise_scale(l, alpha) for l in m.layers])
end

function tensorwise_sum(m1::T, m2::T) where T <: GenericMERA
    n = max(num_translayers(m1), num_translayers(m2)) + 1
    layers = [tensorwise_sum(get_layer(m1, i), get_layer(m2, i)) for i in 1:n]
    return T(layers)
end

function stiefel_inner(m::T, m1::T, m2::T) where T <: GenericMERA
    n = max(num_translayers(m1), num_translayers(m2)) + 1
    inner = sum([stiefel_inner(get_layer(m, i), get_layer(m1, i), get_layer(m2, i))
                 for i in 1:n])
    return inner
end

function euclidean_inner(m::T, m1::T, m2::T) where T <: GenericMERA
    n = max(num_translayers(m1), num_translayers(m2)) + 1
    inner = sum([euclidean_inner(get_layer(m, i), get_layer(m1, i), get_layer(m2, i))
                 for i in 1:n])
    return inner
end

function stiefel_gradient(h, m::T, pars; kwargs...) where T <: GenericMERA
    nt = num_translayers(m)
    layers = []
    for l in 1:nt
        layer = get_layer(m, l)
        rho = densitymatrix(m, l+1)
        hl = ascended_operator(m, h, l)
        grad = stiefel_gradient(hl, rho, layer, pars; kwargs...)
        push!(layers, grad)
    end

    # Special case of the translation invariant layer.
    havg = ascended_operator_avg(m, h, pars, :none)
    layer = get_layer(m, Inf)
    rho = densitymatrix(m, Inf)
    grad = stiefel_gradient(havg, rho, layer, pars; kwargs...)
    push!(layers, grad)
    g = T(layers)
    return g
end

function stiefel_geodesic(m::T, mtan::T, alpha::Number) where T <: GenericMERA
    layers, layers_tan = zip([stiefel_geodesic(l, ltan, alpha)
                              for (l, ltan) in zip(m.layers, mtan.layers)]...)
    return T(layers), T(layers_tan)
end

function cayley_retract(m::T, mtan::T, alpha::Number) where T <: GenericMERA
    layers, layers_tan = zip([cayley_retract(l, ltan, alpha)
                              for (l, ltan) in zip(m.layers, mtan.layers)]...)
    return T(layers), T(layers_tan)
end

function cayley_transport(m::T, mtan::T, mvec::T, alpha::Number) where T <: GenericMERA
    layers = [cayley_transport(l, ltan, lvec, alpha)
              for (l, ltan, lvec) in zip(m.layers, mtan.layers, mvec.layers)]
    return T(layers)
end

function minimize_expectation_grad!(m, h, pars; lowest_depth=1, normalization=noop_firstarg,
                                    vary_disentanglers=true)
    if lowest_depth != 1
        # TODO Could implement this. It's not hard, just haven't seen the need.
        msg = "lowest_depth != 1 has not been implemented for gradient optimization."
        throw(ArgumentError(msg))
    end

    function fg(x)
        f = normalization(expect(h, x))
        g = normalization(stiefel_gradient(h, x, pars;
                                           vary_disentanglers=vary_disentanglers))
        return f, g
    end

    if pars[:retraction] == :geodesic
        retract = stiefel_geodesic
    elseif pars[:retraction] == :cayley
        retract = cayley_retract
    else
        msg = "Unknown retraction $(pars[:retraction])."
        throw(ArgumentError(msg))
    end

    # TODO Defining these here instead of within `if` is just a work-around for limitations
    # of Revise.
    transport_id!(vec1, x, vec2, alpha, endpoint) = vec1
    transport_cay!(vec1, x, vec2, alpha, endpoint) = cayley_transport(x, vec2, vec1, alpha)
    if pars[:transport] == :identity
        transport! = transport_id!
        isometric = false
    elseif pars[:transport] == :cayley
        transport! = transport_cay!
        isometric = true
    else
        msg = "Unknown parallel transport $(pars[:transport])."
        throw(ArgumentError(msg))
    end

    can_inner(m, x, y) = 2*real(stiefel_inner(m, x, y))
    euc_inner(m, x, y) = 2*real(euclidean_inner(m, x, y))
    if pars[:metric] === :canonical
        inner = can_inner
    elseif pars[:metric] === :euclidean
        inner = euc_inner
    else
        msg = "Unknown metric $(pars[:metric])."
        throw(ArgumentError(msg))
    end
    scale!(vec, beta) = tensorwise_scale(vec, beta)
    add!(vec1, vec2, beta) = tensorwise_sum(vec1, scale!(vec2, beta))
    linesearch = HagerZhangLineSearch(; ϵ=pars[:ls_epsilon])

    if pars[:method] == :cg || pars[:method] == :conjugategradient
        if pars[:cg_flavor] == :HagerZhang
            flavor = HagerZhang()
        elseif pars[:cg_flavor] == :HestenesStiefel
            flavor = HestenesStiefel()
        elseif pars[:cg_flavor] == :PolakRibierePolyak
            flavor = PolakRibierePolyak()
        elseif pars[:cg_flavor] == :DaiYuan
            flavor = DaiYuan()
        elseif pars[:cg_flavor] == :FletcherReeves
            flavor = FletcherReeves()
        else
            msg = "Unknown conjugate gradient flavor $(pars[:cg_flavor])"
            throw(ArgumentError(msg))
        end
        alg = ConjugateGradient(; flavor=flavor, maxiter=pars[:maxiter],
                                linesearch=linesearch, verbosity=pars[:verbosity],
                                gradtol=pars[:gradient_delta])
    elseif pars[:method] == :gd || pars[:method] == :gradientdescent
        alg = GradientDescent(; maxiter=pars[:maxiter], linesearch=linesearch,
                              verbosity=pars[:verbosity], gradtol=pars[:gradient_delta])
    elseif pars[:method] == :lbfgs
        alg = LBFGS(pars[:lbfgs_m]; maxiter=pars[:maxiter], linesearch=linesearch,
                    verbosity=pars[:verbosity], gradtol=pars[:gradient_delta])
    else
        msg = "Unknown optimization method $(pars[:method])."
        throw(ArgumentError(msg))
    end
    res = optimize(fg, m, alg; scale! = scale!, add! = add!, retract=retract,
                   inner=inner, transport! = transport!, isometrictransport=isometric)
    m, expectation, normgrad, normgradhistory = res
    @info("Gradient optimization done. Expectation = $(expectation).")
    return m
end
