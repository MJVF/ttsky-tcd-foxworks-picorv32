# Testbench for TCD Foxworks PicoRV32

## How to run

To run the RTL simulation:

Compile one of the two C programs within the `../fw` directory:
```sh
make -C fw clean
make -C fw FWDEFS=-DSIM_FAST PROG=(either selftest or bounce)
cp fw/fw32.hex ./test
```

Then execute the RTL cocotb test

```sh
make -B
```

To run gatelevel simulation, first harden your project and copy `../runs/wokwi/results/final/verilog/gl/{your_module_name}.v` to `gate_level_netlist.v`.

Then run:

```sh
make -B GATES=yes
```

## How to view the waveform file

Using GTKWave

```sh
gtkwave tb.fst tb.gtkw
```

Using Surfer

```sh
surfer tb.fst
```
