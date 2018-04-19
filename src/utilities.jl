#########################
# Expression Predicates #
#########################

is_call(x) = Base.Meta.isexpr(x, :call) && (x.args[1] !== GlobalRef(Core, :tuple))

function is_method_definition(x)
    if isa(x, Expr)
        if x.head == :function
            return true
        elseif x.head == :(=) && isa(x.args[1], Expr)
            lhs = x.args[1]
            if lhs.head == :where
                lhs = lhs.args[1]
            end
            return lhs.head == :call
        end
    end
    return false
end

############################
# Expression Match/Replace #
############################

function replace_match!(replace, ismatch, x)
    if ismatch(x)
        return replace(x)
    elseif isa(x, Array)
        for i in eachindex(x)
            x[i] = replace_match!(replace, ismatch, x[i])
        end
    elseif isa(x, Expr)
        replace_match!(replace, ismatch, x.args)
    end
    return x
end

#######################
# Julia IR/Reflection #
#######################

mutable struct Reflection
    signature::DataType
    method::Method
    static_params::Vector{Any}
    code_info::CodeInfo
end

# Return `Reflection` for signature `S` and `world`, if possible. Otherwise, return `nothing`.
function reflect(::Type{S}, world::UInt = typemax(UInt)) where {S<:Tuple}
    # @safe_debug "looking up method" signature=S world=world
    S.parameters[1].name.module === Core.Compiler && return nothing
    _methods = Base._methods_by_ftype(S, -1, world)
    length(_methods) == 1 || return nothing
    type_signature, raw_static_params, method = first(_methods)
    method_instance = Core.Compiler.code_for_method(method, type_signature, raw_static_params, world, false)
    method_signature = method.sig
    static_params = Any[raw_static_params...]
    code_info = Core.Compiler.retrieve_code_info(method_instance)
    isa(code_info, CodeInfo) || return nothing
    code_info = Core.Compiler.copy_code_info(code_info)
    # @safe_debug "retrieved initial method" method code_info
    return Reflection(S, method, static_params, code_info)
end

function fix_labels_and_gotos!(code::Vector)
    changes = Dict{Int,Int}()
    for (i, stmnt) in enumerate(code)
        if isa(stmnt, LabelNode)
            code[i] = LabelNode(i)
            changes[stmnt.label] = i
        end
    end
    for (i, stmnt) in enumerate(code)
        if isa(stmnt, GotoNode)
            code[i] = GotoNode(get(changes, stmnt.label, stmnt.label))
        elseif Base.Meta.isexpr(stmnt, :enter)
            stmnt.args[1] = get(changes, stmnt.args[1], stmnt.args[1])
        elseif Base.Meta.isexpr(stmnt, :gotoifnot)
            stmnt.args[2] = get(changes, stmnt.args[2], stmnt.args[2])
        end
    end
    return code
end

function copy_prelude_code(code::Vector)
    prelude_code = Any[]
    for stmnt in code
        if isa(stmnt, Nothing) || isa(stmnt, NewvarNode)
            push!(prelude_code, stmnt)
        else
            break
        end
    end
    return prelude_code
end

# there's also `ccall(:jl_get_world_counter, UInt, ())`
get_world_age() = ccall(:jl_get_tls_world_age, UInt, ())

#################
# Miscellaneous #
#################

unquote(x) = x
unquote(x::QuoteNode) = x.value
unquote(x::Expr) = x.head == :quote ? first(x.args) : x

function unqualify_name(e::Expr)
    @assert e.head == :(.)
    return unqualify_name(last(e.args))
end

unqualify_name(name::Symbol) = name

# define safe loggers for use in generated functions (where task switches are not allowed)
for level in [:debug, :info, :warn, :error]
    @eval begin
        macro $(Symbol("safe_$level"))(ex...)
            macrocall = :(@placeholder $(ex...))
            # NOTE: `@placeholder` in order to avoid hard-coding @__LINE__ etc
            macrocall.args[1] = Symbol($"@$level")
            quote
                old_logger = global_logger()
                global_logger(Logging.ConsoleLogger(Core.stderr, old_logger.min_level))
                ret = $(esc(macrocall))
                global_logger(old_logger)
                ret
            end
        end
    end
end
