# TernaryLayer and TernaryMERA types, and methods thereof.
# To be `included` in MERA.jl.

# # # The core stuff

# Index numbering convention is as follows, where the physical indices are at the bottom:
# Disentangler:
#  3|   4|
#  +------+
#  |  u   |
#  +------+
#  1|   2|
#
# Isometry:
#     4|
#  +-------+
#  |   w   |
#  +-------+
#  1| 2| 3|

struct TernaryLayer <: SimpleLayer
    disentangler
    isometry
end

TernaryMERA = GenericMERA{TernaryLayer}

# Implement the iteration and indexing interfaces.
Base.iterate(layer::TernaryLayer) = (layer.disentangler, 1)
Base.iterate(layer::TernaryLayer, state) = state == 1 ? (layer.isometry, 2) : nothing
Base.eltype(::Type{TernaryLayer}) = TensorMap
Base.length(layer::TernaryLayer) = 2
Base.firstindex(layer::TernaryLayer) = 1
Base.lastindex(layer::TernaryLayer) = 2
function Base.getindex(layer::TernaryLayer, i)
    i == 1 && return layer.disentangler
    i == 2 && return layer.isometry
    throw(BoundsError(layer, i))
end

"""
The ratio by which the number of sites changes when go down through this layer.
"""
scalefactor(::Type{TernaryMERA}) = 3

get_disentangler(m::TernaryMERA, depth) = get_layer(m, depth).disentangler
get_isometry(m::TernaryMERA, depth) = get_layer(m, depth).isometry

function set_disentangler!(m::TernaryMERA, u, depth; kwargs...)
    w = get_isometry(m, depth)
    return set_layer!(m, (u, w), depth; kwargs...)
end

function set_isometry!(m::TernaryMERA, w, depth; kwargs...)
    u = get_disentangler(m, depth)
    return set_layer!(m, (u, w), depth; kwargs...)
end

causal_cone_width(::Type{TernaryLayer}) = 2

outputspace(layer::TernaryLayer) = space(layer.disentangler, 1)
inputspace(layer::TernaryLayer) = space(layer.isometry, 4)'

"""
Return a new layer where the isometries have been padded with zeros to change the top vector
space to be V_new.
"""
function expand_inputspace(layer::TernaryLayer, V_new)
    u, w = layer
    w = pad_with_zeros_to(w, 4 => V_new')
    return TernaryLayer(u, w)
end

"""
Return a new layer where the disentanglers and isometries have been padded with zeros to
change the bottom vector space to be V_new.
"""
function expand_outputspace(layer::TernaryLayer, V_new)
    u, w = layer
    u = pad_with_zeros_to(u, 1 => V_new, 2 => V_new, 3 => V_new', 4 => V_new')
    w = pad_with_zeros_to(w, 1 => V_new, 2 => V_new, 3 => V_new)
    return TernaryLayer(u, w)
end

"""
Return a layer with random tensors, with `Vin` and `Vout` as the input and output spaces.
If `random_disentangler=true`, the disentangler is also a random unitary, if `false`
(default), it is the identity.
"""
function randomlayer(::Type{TernaryLayer}, Vin, Vout; random_disentangler=false,
                     T=ComplexF64)
    ufunc(o, i) = (random_disentangler ?
                   randomisometry(o, i, T) :
                   T <: Complex ? complex(isomorphism(o, i)) : isomorphism(o, i))
    u = ufunc(Vout ⊗ Vout, Vout ⊗ Vout)
    w = randomisometry(Vout ⊗ Vout ⊗ Vout, Vin)
    return TernaryLayer(u, w)
end

# # # Stiefel manifold functions

function stiefel_gradient(h, rho, layer::TernaryLayer, pars; vary_disentanglers=true)
    if vary_disentanglers
        uenv = environment_disentangler(h, layer, rho)
    else
        # TODO We could save some subleading computations by not running the whole machinery
        # when uenv .== 0, but this implementation is much simpler.
        V = outputspace(layer)
        uenv = TensorMap(zeros, eltype(layer), V ⊗ V ← V ⊗ V)
    end
    wenv = environment_isometry(h, layer, rho)
    u, w = layer
    # The environment is the partial derivative. We need to turn that into a tangent vector
    # of the Stiefel manifold point u or w.
    if pars[:metric] === :canonical
        projection = stiefel_projection_canonical
    elseif pars[:metric] === :euclidean
        projection = stiefel_projection_euclidean
    end
    ugrad = projection(u, uenv)
    wgrad = projection(w, wenv)
    return TernaryLayer(ugrad, wgrad)
end

function stiefel_geodesic(l::TernaryLayer, ltan::TernaryLayer, alpha::Number)
    u, utan = stiefel_geodesic_unitary(l.disentangler, ltan.disentangler, alpha)
    w, wtan = stiefel_geodesic_isometry(l.isometry, ltan.isometry, alpha)
    return TernaryLayer(u, w), TernaryLayer(utan, wtan)
end

# # # Invariants

"""
Check the compatibility of the legs connecting the disentanglers and the isometries.
Return true/false.
"""
function space_invar_intralayer(layer::TernaryLayer)
    u, w = layer
    matching_bonds = [(space(u, 3)', space(w, 3)),
                      (space(u, 4)', space(w, 1))]
    allmatch = all([==(pair...) for pair in matching_bonds])
    return allmatch
end

"""
Check the compatibility of the legs connecting the isometries of the first layer to the
disentanglers of the layer above it. Return true/false.
"""
function space_invar_interlayer(layer::TernaryLayer, next_layer::TernaryLayer)
    u, w = layer.disentangler, layer.isometry
    unext, wnext = next_layer.disentangler, next_layer.isometry
    matching_bonds = [(space(w, 4)', space(unext, 1)),
                      (space(w, 4)', space(unext, 2))]
    allmatch = all([==(pair...) for pair in matching_bonds])
    return allmatch
end

# # # Ascending and descending superoperators

"""
Return the ascending superoperator of the one site in the middle of the isometries in a
TernaryMERA, as a TensorMap. Unlike most ascending superoperators, this one is actually
affordable to construct as a full tensor.
"""
ascending_superop_onesite(m::TernaryMERA) = ascending_superop_onesite(get_layer(m, Inf))

function ascending_superop_onesite(layer::TernaryLayer)
    w = layer.isometry
    @tensor(superop[-1 -2; -11 -12] := w[1 -2 2; -12] * w'[-11; 1 -1 2])
    return superop
end

"""
Ascend a twosite `op` from the bottom of the given layer to the top.
"""
function ascend(op::SquareTensorMap{2}, layer::TernaryLayer, pos=:avg)
    u, w = layer
    if in(pos, (:left, :l, :L))
        # Cost: 2X^8 + 2X^7 + 2X^6
        @tensor(
                scaled_op[-100 -200; -300 -400] :=
                w[51 52 53; -300 ] * w[54 11 12; -400] *
                u[41 42; 53 54] *
                op[31 32; 52 41] *
                u'[21 55; 32 42] *
                w'[-100; 51 31 21] * w'[-200; 55 11 12]
               )
    elseif in(pos, (:right, :r, :R))
        # Cost: 2X^8 + 2X^7 + 2X^6
        @tensor(
                scaled_op[-100 -200; -300 -400] :=
                w[11 12 65; -300] * w[63 61 62; -400] *
                u[51 52; 65 63] *
                op[31 41; 52 61] *
                u'[64 21; 51 31] *
                w'[-100; 11 12 64] * w'[-200; 21 41 62]
               )
    elseif in(pos, (:middle, :mid, :m, :M))
        # Cost: 6X^6
        @tensor(
                scaled_op[-100 -200; -300 -400] :=
                w[31 32 41; -300] * w[51 21 22; -400] *
                u[1 2; 41 51] *
                op[11 12; 1 2] *
                u'[42 52; 11 12] *
                w'[-100; 31 32 42] * w'[-200; 52 21 22]
               )
    elseif in(pos, (:a, :avg, :average))
        l = ascend(op, layer, :l)
        r = ascend(op, layer, :r)
        m = ascend(op, layer, :m)
        scaled_op = (l+r+m)/3.
    else
        throw(ArgumentError("Unknown position (should be :m, :l, :r, or :avg)."))
    end
    return scaled_op
end

# TODO Would there be a nice way of doing this where I wouldn't have to replicate all the
# network contractions? @ncon could do it, but Jutho's testing says it's significantly
# slower. This is only used for diagonalizing in charge sectors, so having tensors with
# non-trivial charge would also solve this.
"""
Ascend a twosite `op` with an extra free leg from the bottom of the given layer to the top.
"""
function ascend(op::TensorMap{S1,2,3}, layer::TernaryLayer, pos=:avg) where {S1}
    u, w = layer
    if in(pos, (:left, :l, :L))
        # Cost: 2X^8 + 2X^7 + 2X^6
        @tensor(
                scaled_op[-100 -200; -300 -400 -1000] :=
                w[51 52 53; -300] * w[54 11 12; -400] *
                u[41 42; 53 54] *
                op[31 32; 52 41 -1000] *
                u'[21 55; 32 42] *
                w'[-100; 51 31 21] * w'[-200; 55 11 12]
               )
    elseif in(pos, (:right, :r, :R))
        # Cost: 2X^8 + 2X^7 + 2X^6
        @tensor(
                scaled_op[-100 -200; -300 -400 -1000] :=
                w[11 12 65; -300] * w[63 61 62; -400] *
                u[51 52; 65 63] *
                op[31 41; 52 61 -1000] *
                u'[64 21; 51 31] *
                w'[-100; 11 12 64] * w'[-200; 21 41 62]
               )
    elseif in(pos, (:middle, :mid, :m, :M))
        # Cost: 6X^6
        @tensor(
                scaled_op[-100 -200; -300 -400 -1000] :=
                w[31 32 41; -300] * w[51 21 22; -400] *
                u[1 2; 41 51] *
                op[11 12; 1 2 -1000] *
                u'[42 52; 11 12] *
                w'[-100; 31 32 42] * w'[-200; 52 21 22]
               )
    elseif in(pos, (:a, :avg, :average))
        l = ascend(op, layer, :l)
        r = ascend(op, layer, :r)
        m = ascend(op, layer, :m)
        scaled_op = (l+r+m)/3.
    else
        throw(ArgumentError("Unknown position (should be :m, :l, :r, or :avg)."))
    end
    return scaled_op
end

function ascend(op::SquareTensorMap{1}, layer::TernaryLayer, pos=:avg)
    op = expand_support(op, causal_cone_width(TernaryLayer))
    return ascend(op, layer, pos)
end

"""
Decend a twosite `rho` from the top of the given layer to the bottom.
"""
function descend(rho::SquareTensorMap{2}, layer::TernaryLayer, pos=:avg)
    u, w = layer
    if in(pos, (:left, :l, :L))
        # Cost: 2X^8 + 2X^7 + 2X^6
        @tensor(
                scaled_rho[-100 -200; -300 -400] :=
                u'[61 62; -400 63] *
                w'[51; 52 -300 61] * w'[21; 62 11 12] *
                rho[42 22; 51 21] *
                w[52 -100 41; 42] * w[31 11 12; 22] *
                u[-200 63; 41 31]
               )
    elseif in(pos, (:right, :r, :R))
        # Cost: 2X^8 + 2X^7 + 2X^6
        @tensor(
                scaled_rho[-100 -200; -300 -400] :=
                u'[62 61; 63 -300] *
                w'[21; 11 12 62] * w'[51; 61 -400 52] *
                rho[22 42; 21 51] *
                w[11 12 41; 22] * w[31 -200 52; 42] *
                u[63 -100; 41 31]
               )
    elseif in(pos, (:middle, :mid, :m, :M))
        # Cost: 6X^6
        @tensor(
                scaled_rho[-100 -200; -300 -400] :=
                u'[61 62; -300 -400] *
                w'[21; 11 12 61] * w'[41; 62 31 32] *
                rho[22 42; 21 41] *
                w[11 12 51; 22] * w[52 31 32; 42] *
                u[-100 -200; 51 52]
               )
    elseif in(pos, (:a, :avg, :average))
        l = descend(rho, layer, :l)
        r = descend(rho, layer, :r)
        m = descend(rho, layer, :m)
        scaled_rho = (l+r+m)/3.
    else
        throw(ArgumentError("Unknown position (should be :m, :l, :r, or :avg)."))
    end
    return scaled_rho
end

# # # Optimization

"""
Loop over the tensors of the layer, optimizing each one in turn to minimize the expecation
value of `h`. `rho` is the density matrix right above this layer.

Three parameters are expected to be in the dictionary `pars`:
    :layer_iters, for how many times to loop over the tensors within a layer,
    :disentangler_iters, for how many times to loop over the disentangler,
    :isometry_iters, for how many times to loop over the isometry.
"""
function minimize_expectation_ev(h, layer::TernaryLayer, rho, pars; vary_disentanglers=true)
    gradnorm_u, gradnorm_w = 0.0, 0.0
    for i in 1:pars[:layer_iters]
        if vary_disentanglers
            for j in 1:pars[:disentangler_iters]
                layer, gradnorm_u = minimize_expectation_ev_disentangler(h, layer, rho)
            end
        end
        for j in 1:pars[:isometry_iters]
            layer, gradnorm_w = minimize_expectation_ev_isometry(h, layer, rho)
        end
    end
    # We use the last values of gradnorms for u and w to compute this. That's the closest
    # thing to having the gradient norm at the endpoint.
    gradnorm = sqrt(gradnorm_u^2 + gradnorm_w^2)
    return layer, gradnorm
end

"""
Return a new layer, where the disentangler has been changed to the locally optimal one to
minimize the expectation of a twosite operator `h`.
"""
function minimize_expectation_ev_disentangler(h, layer::TernaryLayer, rho)
    uold, wold = layer
    env = environment_disentangler(h, layer, rho)
    U, S, Vt = tsvd(env, (1,2), (3,4))
    u = U * Vt
    # Compute the Stiefel manifold norm of the gradient. Used as a convergence measure.
    uoldenv = uold' * env
    @tensor crossterm[] := uoldenv[1 2; 3 4] * uoldenv[3 4; 1 2]
    gradnorm = sqrt(abs(norm(env)^2 - real(TensorKit.scalar(crossterm))))
    return TernaryLayer(u, wold), gradnorm
end

"""
Return the environment for a disentangler.
"""
function environment_disentangler(h::SquareTensorMap{2}, layer, rho)
    u, w = layer
    # Cost: 2X^8 + 2X^7 + 2X^6
    @tensor(
            env1[-1 -2; -3 -4] :=
            rho[63 22; 31 21] *
            w[61 62 -3; 63] * w[-4 11 12; 22] *
            h[51 52; 62 -1] *
            u'[41 42; 52 -2] *
            w'[31; 61 51 41] * w'[21; 42 11 12]
           )

    # Cost: 6X^6
    @tensor(
            env2[-1 -2; -3 -4] :=
            rho[42 52; 41 51] *
            w[21 22 -3; 42] * w[-4 31 32; 52] *
            h[11 12; -1 -2] *
            u'[61 62; 11 12] *
            w'[41; 21 22 61] * w'[51; 62 31 32]
           )

    # Cost: 2X^8 + 2X^7 + 2X^6
    @tensor(
            env3[-1 -2; -3 -4] :=
            rho[22 63; 21 31] *
            w[12 11 -3; 22] * w[-4 62 61; 63] *
            h[52 51; -2 62] *
            u'[42 41; -1 52] *
            w'[21; 12 11 42] * w'[31; 41 51 61]
           )

    env = (env1 + env2 + env3)/3
    # Complex conjugate.
    env = permute(env', (3,4), (1,2))
    return env
end

"""
Return a new layer, where the isometry has been changed to the locally optimal one to
minimize the expectation of a twosite operator `h`.
"""
function minimize_expectation_ev_isometry(h, layer::TernaryLayer, rho)
    uold, wold = layer
    env = environment_isometry(h, layer, rho)
    U, S, Vt = tsvd(env, (1,2,3), (4,))
    w = U * Vt
    # Compute the Stiefel manifold norm of the gradient. Used as a convergence measure.
    woldenv = wold' * env
    @tensor crossterm[] := woldenv[1; 2] * woldenv[2; 1]
    gradnorm = sqrt(abs(norm(env)^2 - real(TensorKit.scalar(crossterm))))
    return TernaryLayer(uold, w), gradnorm
end

"""
Return the environment for an isometry.
"""
function environment_isometry(h::SquareTensorMap{2}, layer, rho)
    u, w = layer
    # Cost: 2X^8 + 2X^7 + 2X^6
    @tensor(
            env1[-1 -2 -3; -4] :=
            rho[82 -4; 81 84] *
            w[62 61 63; 82] *
            u[51 52; 63 -1] *
            h[41 42; 61 51] *
            u'[31 83; 42 52] *
            w'[81; 62 41 31] * w'[84; 83 -2 -3]
           )

    # Cost: 6X^6
    @tensor(
            env2[-1 -2 -3; -4] :=
            rho[42 -4; 41 62] *
            w[11 12 51; 42] *
            u[21 22; 51 -1] *
            h[31 32; 21 22] *
            u'[52 61; 31 32] *
            w'[41; 11 12 52] * w'[62; 61 -2 -3]
           )

    # Cost: 2X^8 + 2X^7 + 2X^6
    @tensor(
            env3[-1 -2 -3; -4] :=
            rho[32 -4; 31 33] *
            w[21 11 73; 32] *
            u[72 71; 73 -1] *
            h[62 61; 71 -2] *
            u'[51 41; 72 62] *
            w'[31; 21 11 51] * w'[33; 41 61 -3]
           )

    # Cost: 2X^8 + 2X^7 + 2X^6
    @tensor(
            env4[-1 -2 -3; -4] :=
            rho[-4 32; 33 31] *
            w[73 11 21; 32] *
            u[71 72; -3 73] *
            h[61 62; -2 71] *
            u'[41 51; 62 72] *
            w'[33; -1 61 41] * w'[31; 51 11 21]
           )

    # Cost: 6X^6
    @tensor(
            env5[-1 -2 -3; -4] :=
            rho[-4 42; 62 41] *
            w[51 12 11; 42] *
            u[22 21; -3 51] *
            h[32 31; 22 21] *
            u'[61 52; 32 31] *
            w'[62; -1 -2 61] * w'[41; 52 12 11]
           )

    # Cost: 2X^8 + 2X^7 + 2X^6
    @tensor(
            env6[-1 -2 -3; -4] :=
            rho[-4 82; 84 81] *
            w[63 61 62; 82] *
            u[52 51; -3 63] *
            h[42 41; 51 61] *
            u'[83 31; 52 42] *
            w'[84; -1 -2 83] * w'[81; 31 41 62]
           )

    env = (env1 + env2 + env3 + env4 + env5 + env6)/3
    # Complex conjugate.
    env = permute(env', (2,3,4), (1,))
    return env
end
