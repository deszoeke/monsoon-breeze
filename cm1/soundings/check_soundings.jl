# Check that the experiments built in helpers/ekamsat_soundings.jl equal the CM1 input_sounding files.
#
#     julia --project cm1/soundings/check_soundings.jl

using MonsoonConvection

include(joinpath(@__DIR__, "..", "..", "helpers", "ekamsat_soundings.jl"))

control    = ekamsat_control()
exp1       = interp_1200_7200(control)
with_4800m = restore_4800m_level(exp1)
dry        = dry_layer(with_4800m, 0.3, (4800.0, 7200.0))

experiments = [
    "AS20230617"     => control,
    "AS12007200"     => exp1,
    "ASu4800-8"      => shear_set_4800m_u(with_4800m; u = -8.0),
    "ASu4800-7p2"    => shear_set_4800m_u(with_4800m; u = -7.2),
    "ASu4800-p4"     => shear_set_4800m_u(with_4800m; u = -0.4),
    "ASdry4800-7200" => dry,
    "ASdryu4800-8"   => shear_set_4800m_u(dry; u = -8.0),
]

same(a, b) = all(getfield(a, k) == getfield(b, k) for k in fieldnames(Sounding))

all_same = true
for (name, table) in experiments
    file = read_cm1_sounding(joinpath(@__DIR__, "input_sounding.$name"))
    ok = same(ekamsat_sounding(table), file)
    global all_same &= ok
    println(rpad(name, 16), ok ? "matches its CM1 file" : "DIFFERS from its CM1 file")
end
all_same || exit(1)
