set assert_output_stop_level INACTIVE
set assert_stop_level NEVER
set assert_report_level NEVER

database -open waves -into wave.shm -default
probe -create -database waves tb_pta_sub_system -depth all
probe -create -all -morories -unpacked 65536 -packed 0 -depth all

run 600us
