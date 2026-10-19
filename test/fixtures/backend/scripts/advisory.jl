function evaluate_syntax(expression::Expr)
    return Core.eval(@__MODULE__,expression)
end
