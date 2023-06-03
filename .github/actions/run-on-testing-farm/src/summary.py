import argparse
import xml.etree.ElementTree as ET


def parse_result(results):

    tree = ET.parse(results)
    root = tree.getroot()

    for testsuite in root.findall('testsuite'):
        name = testsuite.get('name')
        overall = testsuite.get('result')
        num_tests = testsuite.get('tests')
        formatted_logs = "No logs found"
        logs = testsuite.find('logs')

        if logs:
            logs_list = map(lambda x: f"[{x[0]}]({x[1]})",
                            map(lambda l: (l.get('name'), l.get('href')), logs.findall('log')))
            formatted_logs = ", ".join(logs_list)
        # Print 1 line table with overall result as the summary
        print("|Test suite| Result | Logs |")
        print("|----------|--------|------|")
        print(f"| {name} | {overall} | {formatted_logs}|")
        print(f"<details><summary>Test details</summary>")
        print("<p>\n")
        print("| Test | Result | Logs |")
        print("|------|--------|------|")
        for testcase in testsuite.findall('testcase'):
            name = testcase.get('name')
            result = testcase.get('result')
            formatted_logs = "No logs found"
            logs = testcase.find('logs')
            if logs:
                logs_list = map(lambda x: f"[{x[0]}]({x[1]})",
                                map(lambda l: (l.get('name'), l.get('href')), logs.findall('log')))
                formatted_logs = ", ".join(logs_list)
            print(f"| {name} | {result} | {formatted_logs}|")
        print("\n</p>")
        print("</details>")


def main():
    parser = argparse.ArgumentParser(
        description="Print results in markdown format")

    parser.add_argument(
        'filename', help="The file containing the xunit xml file returned by Testing Farm")

    args = parser.parse_args()

    if args.filename:
        parse_result(args.filename)
    else:
        print("No results to show")


if __name__ == "__main__":
    main()
