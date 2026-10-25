"""scripts/macho_func_cmp.py (the morning check of winemac.so): every body of a name that occurs twice is compared."""
from pathlib import Path
import importlib.util
import unittest

PROJECT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("macho_func_cmp", PROJECT / "scripts/macho_func_cmp.py")
cmp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cmp)


def objdump(flush1, flush2):
    # two static functions with the same name, as in winemac.so (opengl.c and surface.c)
    return f"""
winemac.so:	file format mach-o 64-bit x86-64

Disassembly of section __TEXT,__text:

000000000003d730 <_macdrv_surface_flush>:
   3d730:	pushq	%rbp
   3d731:	{flush1}
   3d736:	callq	0x3d9e0 <_enable_mp_engine> ## call
000000000003d9e0 <_enable_mp_engine>:
   3d9e0:	retq
000000000003e770 <_macdrv_surface_flush>:
   3e770:	pushq	%rbp
   3e771:	{flush2}
"""


class FunctionCompareTests(unittest.TestCase):
    def test_a_name_that_occurs_twice_keeps_both_bodies(self):
        fs = cmp.parse(objdump("movq %rdi, %rbx", "movq %rsi, %rbx"))
        self.assertEqual(sorted(fs), [("_enable_mp_engine", 1), ("_macdrv_surface_flush", 1), ("_macdrv_surface_flush", 2)])
        self.assertEqual(fs[("_macdrv_surface_flush", 1)][1], "movq %rdi, %rbx")
        self.assertEqual(fs[("_macdrv_surface_flush", 2)][1], "movq %rsi, %rbx")

    def test_a_change_in_the_first_body_shows(self):
        a = cmp.parse(objdump("movq %rdi, %rbx", "movq %rsi, %rbx"))
        b = cmp.parse(objdump("movq %rdx, %rbx", "movq %rsi, %rbx"))
        self.assertEqual(cmp.report(a, b), ["functions: 3 vs 3; differing: 1",
                                            "  _macdrv_surface_flush#1: 3 vs 3 instructions"])

    def test_addresses_and_comments_do_not_count(self):
        a = cmp.parse(objdump("movq %rdi, %rbx", "movq %rsi, %rbx"))
        b = cmp.parse(objdump("movq %rdi, %rbx", "movq %rsi, %rbx").replace("0x3d9e0", "0x4d9e0").replace("## call", ""))
        self.assertEqual(cmp.report(a, b), ["functions: 3 vs 3; differing: 0"])

    def test_a_body_in_one_build_only_shows(self):
        a = cmp.parse(objdump("movq %rdi, %rbx", "movq %rsi, %rbx"))
        b = cmp.parse(objdump("movq %rdi, %rbx", "movq %rsi, %rbx") + "000000000003f000 <_new_helper>:\n   3f000:\tretq\n")
        self.assertEqual(cmp.report(a, b), ["functions: 3 vs 4; differing: 1",
                                            "  _new_helper#1: 0 vs 1 instructions (only in one)"])


if __name__ == "__main__":
    unittest.main()
