import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('ui_results', Path(__file__).resolve().parents[1] / 'verify_ui_results.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class UIResultTests(unittest.TestCase):
    def test_repeated_case_cannot_replace_missing_case(self):
        summary = dict(result='Passed', passedTests=2, totalTestCount=2,
                       failedTests=0, skippedTests=0, expectedFailures=0)
        case = dict(name='testFirst()', nodeType='Test Case', result='Passed')
        with self.assertRaises(ValueError):
            module.validate(summary, 'func testFirst() {}\nfunc testSecond() {}',
                            {'testNodes': [case, case]})

    def test_complete_run_passes(self):
        self.assertEqual(module.validate(dict(result='Passed', passedTests=2, totalTestCount=2,
                                             failedTests=0, skippedTests=0, expectedFailures=0),
                                         'func testFirst() {}\nfunc testSecond() {}',
                                         {'testNodes': [{'nodeType': 'Test Suite', 'children': [
                                             {'name': 'testFirst()', 'nodeType': 'Test Case', 'result': 'Passed'},
                                             {'name': 'ApexTermUITests/testSecond()', 'nodeType': 'Test Case', 'result': 'Passed'}]}]}), 2)

    def test_empty_partial_failed_or_skipped_run_is_rejected(self):
        baseline = dict(result='Passed', passedTests=2, totalTestCount=2,
                        failedTests=0, skippedTests=0, expectedFailures=0)
        for patch in [dict(passedTests=0, totalTestCount=0), dict(passedTests=1),
                      dict(result='Failed'), dict(skippedTests=1), dict(failedTests=1),
                      dict(expectedFailures=1), dict(totalTestCount=3)]:
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                module.validate(baseline | patch, 'func testFirst() {}\nfunc testSecond() {}')
