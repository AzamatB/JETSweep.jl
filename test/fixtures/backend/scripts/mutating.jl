macro mutate_original_source()
    if get(ENV,"JETSWEEP_MUTATION_TARGET","") == @__FILE__
        open(@__FILE__, "a") do io
            println(io, "# Intentional input change during macro expansion")
        end
    end
    return :(nothing)
end
@mutate_original_source
