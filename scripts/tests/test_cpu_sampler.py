import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    'cpu_sampler', Path(__file__).resolve().parents[1] / 'verification/sample_process_cpu.py')
sampler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sampler)


class CPUSamplerTests(unittest.TestCase):
    def test_ps_elapsed_cpu_formats(self):
        for value, expected in [('00:00.25', 0.25), ('12:34.50', 754.5),
                                ('1:02:03.5', 3723.5)]:
            with self.subTest(value=value):
                self.assertEqual(sampler.cpu_seconds(value), expected)

    def test_invalid_counters_cannot_produce_acceptance_numbers(self):
        for value in ['', '12', '1:2:3:4', '00:nan', '00:inf', '00:-1']:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    sampler.cpu_seconds(value)
