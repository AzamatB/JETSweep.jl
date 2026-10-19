local_helper(x::Int) = x + 1
explicit_main_helper(x::Int) = Main.local_helper(x)
explicit_main_helper(1)
