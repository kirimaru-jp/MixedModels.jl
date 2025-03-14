function MixedModel(f::FormulaTerm, tbl; kwargs...)
    return LinearMixedModel(f::FormulaTerm, tbl; kwargs...)
end

function MixedModel(
    f::FormulaTerm, tbl, d::Distribution, l::Link=canonicallink(d); kwargs...
)
    return GeneralizedLinearMixedModel(f, tbl, d, l; kwargs...)
end

function MixedModel(
    f::FormulaTerm, tbl, d::Normal, l::IdentityLink=IdentityLink(); kwargs...
)
    return LinearMixedModel(f, tbl; kwargs...)
end

function StatsBase.coefnames(m::MixedModel)
    Xtrm = m.feterm
    return invpermute!(copy(Xtrm.cnames), Xtrm.piv)
end

"""
cond(m::MixedModel)

Return a vector of condition numbers of the λ matrices for the random-effects terms
"""
LinearAlgebra.cond(m::MixedModel) = cond.(m.λ)

function StatsBase.dof(m::MixedModel)
    return m.feterm.rank + length(m.parmap) + dispersion_parameter(m)
end

"""
    dof_residual(m::MixedModel)

  Return the residual degrees of freedom of the model.

!!! note
  The residual degrees of freedom for mixed-effects models is not clearly defined due to partial pooling.
  The classical `nobs(m) - dof(m)` fails to capture the extra freedom granted by the random effects, but
  `nobs(m) - nranef(m)` would overestimate the freedom granted by the random effects. `nobs(m) - sum(leverage(m))`
  provides a nice balance based on the relative influence of each observation, but is computationally
  expensive for large models. This problem is also fundamentally related to [long-standing debates](https://bbolker.github.io/mixedmodels-misc/glmmFAQ.html#why-doesnt-lme4-display-denominator-degrees-of-freedomp-values-what-other-options-do-i-have)
  about the appropriate treatment of the denominator degrees of freedom for ``F``-tests.
  In the future, MixedModels.jl may provide additional methods allowing the user to choose the computation
  to use.

!!! warning
   Currently, the residual degrees of freedom is computed as `nobs(m) - dof(m)`, but this may change in
   the future without being considered a breaking change because there is no canonical definition of the
   residual degrees of freedom in a mixed-effects model.
"""
function StatsBase.dof_residual(m::MixedModel)
    # a better estimate might be nobs(m) - sum(leverage(m))
    # this version subtracts the number of variance parameters which isn't really a dimensional
    # and doesn't even agree with the definition for linear models
    return nobs(m) - dof(m)
end

"""
    issingular(m::MixedModel, θ=m.θ)

Test whether the model `m` is singular if the parameter vector is `θ`.

Equality comparisons are used b/c small non-negative θ values are replaced by 0 in `fit!`.

!!! note
    For `GeneralizedLinearMixedModel`, the entire parameter vector (including
    β in the case `fast=false`) must be specified if the default is not used.
"""
issingular(m::MixedModel, θ=m.θ) = any(lowerbd(m) .== θ)
issingular(m::GeneralizedLinearMixedModel, θ=m.optsum.final) = any(lowerbd(m) .== θ)

# FIXME: better to base this on m.optsum.returnvalue
StatsBase.isfitted(m::MixedModel) = m.optsum.feval > 0

StatsBase.meanresponse(m::MixedModel) = mean(m.y)

"""
    modelmatrix(m::MixedModel)

Returns the model matrix `X` for the fixed-effects parameters, as returned by [`coef`](@ref).

This is always the full model matrix in the original column order and from a field in the model
struct.  It should be copied if it is to be modified.
"""
StatsBase.modelmatrix(m::MixedModel) = m.feterm.x

StatsBase.nobs(m::MixedModel) = length(m.y)

StatsBase.predict(m::MixedModel) = fitted(m)

function retbl(mat, trm)
    return merge(
        NamedTuple{(fname(trm),)}((trm.levels,)),
        columntable(Tables.table(transpose(mat); header=Symbol.(trm.cnames))),
    )
end

"""
    raneftables(m::MixedModel; uscale = false)

Return the conditional means of the random effects as a `NamedTuple` of columntables
"""
function raneftables(m::MixedModel{T}; uscale=false) where {T}
    return NamedTuple{fnames(m)}((map(retbl, ranef(m; uscale=uscale), m.reterms)...,))
end

StatsBase.residuals(m::MixedModel) = response(m) .- fitted(m)

"""
    response(m::MixedModel)

Return the response vector for the model.

For a linear mixed model this is a `view` of the last column of the `XyMat` field.
For a generalized linear mixed model this is the `m.resp.y` field.
In either case it should be copied if it is to be modified.
"""
StatsBase.response(m::MixedModel) = m.y

function StatsBase.responsename(m::MixedModel)
    cnm = coefnames(m.formula.lhs)
    return isa(cnm, Vector{String}) ? first(cnm) : cnm
end

function σs(m::MixedModel)
    σ = dispersion(m)
    return NamedTuple{fnames(m)}(((σs(t, σ) for t in m.reterms)...,))
end

function σρs(m::MixedModel)
    σ = dispersion(m)
    return NamedTuple{fnames(m)}(((σρs(t, σ) for t in m.reterms)...,))
end

"""
    size(m::MixedModel)

Returns the size of a mixed model as a tuple of length four:
the number of observations, the number of (non-singular) fixed-effects parameters,
the number of conditional modes (random effects), the number of grouping variables
"""
function Base.size(m::MixedModel)
    dd = m.dims
    return dd.n, dd.p, sum(size.(m.reterms, 2)), dd.nretrms
end

"""
    vcov(m::MixedModel; corr=false)

Returns the variance-covariance matrix of the fixed effects.
If `corr` is `true`, the correlation of the fixed effects is returned instead.
"""
function StatsBase.vcov(m::MixedModel; corr=false)
    Xtrm = m isa GeneralizedLinearMixedModel ? m.LMM.feterm : m.feterm
    iperm = invperm(Xtrm.piv)
    p = length(iperm)
    r = Xtrm.rank
    Linv = inv(feL(m))
    T = eltype(Linv)
    permvcov = dispersion(m, true) * (Linv'Linv)
    if p == Xtrm.rank
        vv = permvcov[iperm, iperm]
    else
        covmat = fill(zero(T) / zero(T), (p, p))
        for j in 1:r, i in 1:r
            covmat[i, j] = permvcov[i, j]
        end
        vv = covmat[iperm, iperm]
    end

    return corr ? StatsBase.cov2cor!(vv, stderror(m)) : vv
end

StatsModels.formula(m::MixedModel) = m.formula
