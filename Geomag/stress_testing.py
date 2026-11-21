"""Deterministic fault-injection benchmark for localization recovery.

This module is a development/evaluation tool. Fault injection is disabled in
normal positioning runs and never modifies the recorded source files.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np

from Geomag.branching import BranchConfig, run_own_branch
from Geomag.own_dataset_registry import (
    assert_own_dataset_evaluable,
    default_own_evaluation_keys,
)

DEFAULT_FAULT_SCENARIOS = (
    {
        "name": "magnetic_bias",
        "kind": "magnetic_bias",
        "start_fraction": 0.25,
        "end_fraction": 0.75,
        "magnitude": 30.0,
        "seed": 20260801,
    },
    {
        "name": "magnetic_noise",
        "kind": "magnetic_noise",
        "start_fraction": 0.25,
        "end_fraction": 0.75,
        "magnitude": 22.0,
        "seed": 20260802,
    },
    {
        "name": "magnetic_dropout",
        "kind": "magnetic_dropout",
        "start_fraction": 0.25,
        "end_fraction": 0.75,
        "magnitude": 0.0,
        "seed": 20260803,
    },
    {
        "name": "gyro_bias",
        "kind": "gyro_bias",
        "start_fraction": 0.25,
        "end_fraction": 0.75,
        "magnitude": 0.90,
        "seed": 20260804,
    },
    {
        "name": "initial_position_offset",
        "kind": "initial_position_offset",
        "start_fraction": 0.0,
        "end_fraction": 0.30,
        "magnitude": 2.0,
        "seed": 20260805,
    },
)


def default_fault_scenarios():
    return [dict(item) for item in DEFAULT_FAULT_SCENARIOS]


def _finite_stats(values):
    arr = np.asarray(values, dtype=float).reshape(-1)
    arr = arr[np.isfinite(arr)]
    if arr.size == 0:
        return {"count": 0, "mean_m": None, "max_m": None, "p95_m": None}
    return {
        "count": int(arr.size),
        "mean_m": float(np.mean(arr)),
        "max_m": float(np.max(arr)),
        "p95_m": float(np.percentile(arr, 95)),
    }


def _phase_stats(error_series, indices):
    errors = np.asarray(error_series or [], dtype=float).reshape(-1)
    selected = [errors[index] for index in indices if 0 <= index < errors.size]
    return _finite_stats(selected)


def _first_sustained_healthy_step(health, start_index, required=3):
    streak = 0
    streak_start = None
    for index in range(max(0, int(start_index)), len(health)):
        if str(health[index].get("status", "healthy")) == "healthy":
            if streak == 0:
                streak_start = index
            streak += 1
            if streak >= max(1, int(required)):
                return int(streak_start)
        else:
            streak = 0
            streak_start = None
    return None


def evaluate_stress_result(
    payload,
    baseline_payload=None,
    recovery_confirmation_steps=3,
    convergence_tolerance_m=0.75,
):
    """Evaluate detection, recovery latency, false actions, and error phases."""
    health = list(payload.get("localization_health_history") or [])
    if not health:
        raise ValueError("Stress result has no localization health history.")
    fault_mask = [bool(value) for value in payload.get("fault_active_step_history", [])]
    if len(fault_mask) != len(health):
        raise ValueError(
            "fault_active_step_history and localization_health_history must "
            "have the same length."
        )
    active_indices = [index for index, active in enumerate(fault_mask) if active]
    if not active_indices:
        raise ValueError("Stress result contains no fault-active localization steps.")
    onset = int(active_indices[0])
    end = int(active_indices[-1])
    warning_indices = [
        index
        for index, sample in enumerate(health)
        if str(sample.get("status", "healthy")) != "healthy"
    ]
    warnings_during_fault = [
        index for index in warning_indices if onset <= index <= end
    ]
    warnings_after_fault = [index for index in warning_indices if index > end]
    first_warning = warnings_during_fault[0] if warnings_during_fault else None
    first_late_warning = warnings_after_fault[0] if warnings_after_fault else None
    events = list(payload.get("localization_recovery_events") or [])
    action_indices = [int(event["step_index"]) for event in events]
    first_action = min(action_indices) if action_indices else None
    first_expand = next(
        (
            int(event["step_index"])
            for event in events
            if event.get("action") == "expand_search"
        ),
        None,
    )
    first_reinitialize = next(
        (
            int(event["step_index"])
            for event in events
            if str(event.get("action", "")).startswith("reinitialize")
        ),
        None,
    )
    recovered_step = (
        _first_sustained_healthy_step(
            health,
            end + 1,
            required=recovery_confirmation_steps,
        )
        if first_warning is not None
        else None
    )

    before_indices = list(range(0, onset))
    during_indices = active_indices
    after_indices = list(range(end + 1, len(health)))
    before_error = _phase_stats(payload.get("pf_error_series"), before_indices)
    during_error = _phase_stats(payload.get("pf_error_series"), during_indices)
    after_error = _phase_stats(payload.get("pf_error_series"), after_indices)
    baseline_during_error = (
        _phase_stats(baseline_payload.get("pf_error_series"), during_indices)
        if baseline_payload is not None
        else None
    )
    tail_count = max(3, int(math.ceil(len(health) * 0.20)))
    tail_error = _phase_stats(
        payload.get("pf_error_series"),
        range(max(0, len(health) - tail_count), len(health)),
    )
    baseline_tail_error = (
        _phase_stats(
            baseline_payload.get("pf_error_series"),
            range(
                max(
                    0,
                    len(baseline_payload.get("pf_error_series") or [])
                    - tail_count,
                ),
                len(baseline_payload.get("pf_error_series") or []),
            ),
        )
        if baseline_payload is not None
        else None
    )
    allowed_tail_mean = (
        1.5
        if baseline_tail_error is None
        or baseline_tail_error["mean_m"] is None
        else float(baseline_tail_error["mean_m"])
        + float(convergence_tolerance_m)
    )
    final_status = str(health[-1].get("status", "unknown"))
    final_reconverged = bool(
        final_status == "healthy"
        and tail_error["mean_m"] is not None
        and float(tail_error["mean_m"]) <= allowed_tail_mean
    )

    predicted = np.asarray(
        [str(sample.get("status", "healthy")) != "healthy" for sample in health],
        dtype=bool,
    )
    truth = np.asarray(fault_mask, dtype=bool)
    true_positive = int(np.count_nonzero(predicted & truth))
    false_positive = int(np.count_nonzero(predicted & ~truth))
    false_negative = int(np.count_nonzero(~predicted & truth))
    precision = (
        None
        if true_positive + false_positive == 0
        else float(true_positive / (true_positive + false_positive))
    )
    recall = (
        None
        if true_positive + false_negative == 0
        else float(true_positive / (true_positive + false_negative))
    )
    false_warning_before_fault = [index for index in warning_indices if index < onset]
    false_actions_before_fault = [index for index in action_indices if index < onset]
    fault_impact_mean_error_m = (
        None
        if baseline_during_error is None
        or baseline_during_error["mean_m"] is None
        or during_error["mean_m"] is None
        else float(
            during_error["mean_m"] - baseline_during_error["mean_m"]
        )
    )
    fault_kind = str((payload.get("fault_injection") or {}).get("kind", ""))
    fault_spec = dict(payload.get("fault_injection") or {})
    position_degraded = bool(
        fault_impact_mean_error_m is not None
        and fault_impact_mean_error_m >= 0.50
    )
    integrity_fault = fault_kind in {
        "magnetic_dropout",
        "gyro_bias",
        "initial_position_offset",
    }
    detection_required = bool(
        fault_spec.get(
            "detection_required",
            position_degraded or integrity_fault,
        )
    )
    recovery_required = bool(
        fault_spec.get("recovery_required", integrity_fault)
    )
    unnecessary_action_indices = (
        list(action_indices) if not detection_required else []
    )
    false_action_indices = sorted(
        set(false_actions_before_fault + unnecessary_action_indices)
    )
    benchmark_passed = bool(
        (not detection_required or first_warning is not None)
        and not false_action_indices
        and (not (position_degraded or recovery_required) or final_reconverged)
    )

    return {
        "dataset_key": payload.get("dataset_key"),
        "scenario": dict(payload.get("fault_injection") or {}),
        "steps_detected": int(payload.get("steps_detected", len(health) - 1)),
        "fault_start_step": onset,
        "fault_end_step": end,
        "anomaly_detected": first_warning is not None,
        "first_warning_step": first_warning,
        "late_warning_step": first_late_warning,
        "late_warning_only": bool(
            first_warning is None and first_late_warning is not None
        ),
        "warning_delay_steps": (
            None if first_warning is None else int(first_warning - onset)
        ),
        "first_recovery_action_step": first_action,
        "recovery_action_delay_steps": (
            None if first_action is None else int(first_action - onset)
        ),
        "first_expand_search_step": first_expand,
        "first_reinitialize_step": first_reinitialize,
        "recovered": recovered_step is not None,
        "recovered_step": recovered_step,
        "recovery_delay_steps": (
            None if recovered_step is None else int(recovered_step - end)
        ),
        "recovery_event_count": len(events),
        "false_warning_steps_before_fault": false_warning_before_fault,
        "false_recovery_action_steps_before_fault": false_actions_before_fault,
        "unnecessary_recovery_action_steps": unnecessary_action_indices,
        "false_recovery_action_steps": false_action_indices,
        "false_recovery": bool(false_action_indices),
        "detection_precision": precision,
        "detection_recall": recall,
        "detection_required": detection_required,
        "recovery_required": recovery_required,
        "position_degraded": position_degraded,
        "error_before_fault": before_error,
        "error_during_fault": during_error,
        "error_after_fault": after_error,
        "baseline_error_during_fault": baseline_during_error,
        "fault_impact_mean_error_m": fault_impact_mean_error_m,
        "tail_error": tail_error,
        "baseline_tail_error": baseline_tail_error,
        "error_improvement_after_fault_m": (
            None
            if during_error["mean_m"] is None or after_error["mean_m"] is None
            else float(during_error["mean_m"] - after_error["mean_m"])
        ),
        "final_status": final_status,
        "final_reconverged": final_reconverged,
        "allowed_tail_mean_m": allowed_tail_mean,
        "benchmark_passed": benchmark_passed,
    }


def evaluate_baseline_health(payload):
    health = list(payload.get("localization_health_history") or [])
    warning_steps = [
        index
        for index, sample in enumerate(health)
        if str(sample.get("status", "healthy")) != "healthy"
    ]
    events = list(payload.get("localization_recovery_events") or [])
    return {
        "steps_detected": int(payload.get("steps_detected", len(health) - 1)),
        "warning_step_count": len(warning_steps),
        "warning_steps": warning_steps,
        "false_recovery_event_count": len(events),
        "false_recovery": bool(events),
        "final_status": (
            str(health[-1].get("status", "unknown")) if health else "unknown"
        ),
        "pf_error_stats": payload.get("pf_error_stats"),
        "pf_endpoint_error_m": payload.get("pf_endpoint_error_m"),
    }


def _flat_row(dataset_key, evaluation):
    scenario = evaluation["scenario"]
    return {
        "dataset_key": dataset_key,
        "scenario": scenario.get("name", scenario.get("kind")),
        "fault_kind": scenario.get("kind"),
        "fault_start_step": evaluation["fault_start_step"],
        "fault_end_step": evaluation["fault_end_step"],
        "anomaly_detected": evaluation["anomaly_detected"],
        "warning_delay_steps": evaluation["warning_delay_steps"],
        "late_warning_only": evaluation["late_warning_only"],
        "late_warning_step": evaluation["late_warning_step"],
        "recovery_event_count": evaluation["recovery_event_count"],
        "recovery_action_delay_steps": evaluation[
            "recovery_action_delay_steps"
        ],
        "recovery_delay_steps": evaluation["recovery_delay_steps"],
        "false_recovery": evaluation["false_recovery"],
        "final_reconverged": evaluation["final_reconverged"],
        "detection_precision": evaluation["detection_precision"],
        "detection_recall": evaluation["detection_recall"],
        "detection_required": evaluation["detection_required"],
        "recovery_required": evaluation["recovery_required"],
        "position_degraded": evaluation["position_degraded"],
        "fault_impact_mean_error_m": evaluation[
            "fault_impact_mean_error_m"
        ],
        "before_mean_error_m": evaluation["error_before_fault"]["mean_m"],
        "during_mean_error_m": evaluation["error_during_fault"]["mean_m"],
        "during_max_error_m": evaluation["error_during_fault"]["max_m"],
        "after_mean_error_m": evaluation["error_after_fault"]["mean_m"],
        "after_max_error_m": evaluation["error_after_fault"]["max_m"],
        "error_improvement_after_fault_m": evaluation[
            "error_improvement_after_fault_m"
        ],
        "tail_mean_error_m": evaluation["tail_error"]["mean_m"],
        "final_status": evaluation["final_status"],
        "benchmark_passed": evaluation["benchmark_passed"],
    }


def _display(value, digits=3):
    if value is None:
        return "—"
    if isinstance(value, bool):
        return "是" if value else "否"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def _markdown_report(report):
    aggregate = report["aggregate"]
    lines = [
        "# 定位异常压力测试报告",
        "",
        "> 本报告由确定性故障注入生成；原始采集文件未被修改。",
        "",
        "## 总览",
        "",
        f"- 数据集：{', '.join(report['configuration']['dataset_keys'])}",
        f"- 场景总数：{aggregate['scenario_count']}",
        (
            "- 必须检测的场景："
            f"{aggregate['required_anomaly_detected_count']}/"
            f"{aggregate['detection_required_count']}"
        ),
        (
            "- 异常结束后恢复稳定："
            f"{aggregate['recovered_count']}/{aggregate['scenario_count']}"
        ),
        (
            "- 最终重新收敛："
            f"{aggregate['final_reconverged_count']}/"
            f"{aggregate['scenario_count']}"
        ),
        f"- 误恢复场景：{aggregate['false_recovery_count']}",
        f"- 综合通过：{aggregate['benchmark_pass_count']}/{aggregate['scenario_count']}",
        "",
    ]
    for dataset_key, dataset in report["datasets"].items():
        baseline = dataset["baseline"]
        lines.extend(
            [
                f"## {dataset_key}",
                "",
                (
                    "正常基线："
                    f"{baseline['warning_step_count']} 个低可靠步，"
                    f"{baseline['false_recovery_event_count']} 次误恢复，"
                    f"最终状态 `{baseline['final_status']}`。"
                ),
                "",
                "| 场景 | 必须检测 | 已检测 | 预警延迟/步 | 恢复延迟/步 | 误差影响/m | 最终收敛 | 误恢复 | 通过 |",
                "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
            ]
        )
        for name, result in dataset["scenarios"].items():
            lines.append(
                "| "
                + " | ".join(
                    [
                        name,
                        _display(result["detection_required"]),
                        _display(result["anomaly_detected"]),
                        _display(result["warning_delay_steps"]),
                        _display(result["recovery_delay_steps"]),
                        _display(result["fault_impact_mean_error_m"]),
                        _display(result["final_reconverged"]),
                        _display(result["false_recovery"]),
                        _display(result["benchmark_passed"]),
                    ]
                )
                + " |"
            )
        lines.append("")
    lines.extend(
        [
            "## 判定说明",
            "",
            "- 只有在注入窗口内出现非健康状态才算检测成功；窗口结束后的首次提示单独记录为迟到预警。",
            "- 磁力计失效、陀螺仪持续偏置和起点偏移均必须检测；其他扰动在定位平均误差相对基线增加至少 0.50 m 时也必须检测。",
            "- 连续 3 步恢复健康状态才记为恢复稳定。",
            "- 最后 20% 路径误差不超过基线同期均值 0.75 m 且最终状态健康，才记为最终重新收敛。",
            "- 三类完整性故障还必须最终重新收敛；在无需检测的扰动中触发扩搜/重初始化，或异常开始前触发恢复，均记为误恢复。",
            "",
        ]
    )
    return "\n".join(lines)


def run_stress_benchmark(
    dataset_keys=None,
    scenarios=None,
    output_dir="results/localization_stress",
    generate_plots=False,
    reuse_existing=False,
):
    keys = list(dataset_keys or default_own_evaluation_keys())
    fault_scenarios = [dict(item) for item in (scenarios or default_fault_scenarios())]
    if not fault_scenarios:
        raise ValueError("At least one fault scenario is required.")
    output_root = Path(output_dir)
    output_root.mkdir(parents=True, exist_ok=True)
    datasets = {}
    flat_rows = []

    for dataset_key in keys:
        spec = assert_own_dataset_evaluable(dataset_key)
        dataset_dir = output_root / dataset_key
        dataset_dir.mkdir(parents=True, exist_ok=True)
        baseline_json = dataset_dir / "baseline.json"
        baseline_png = dataset_dir / "baseline.png" if generate_plots else None
        baseline = (
            json.loads(baseline_json.read_text(encoding="utf-8"))
            if reuse_existing and baseline_json.exists()
            else run_own_branch(
                BranchConfig(
                    branch="own",
                    own_profile="package",
                    own_data_source="registry",
                    own_dataset_key=dataset_key,
                    own_data_dir=spec["dataset_dir"],
                    show=False,
                    write_outputs=False,
                    output_json=str(baseline_json),
                    output_png=(
                        None if baseline_png is None else str(baseline_png)
                    ),
                )
            )
        )
        scenario_results = {}
        for scenario in fault_scenarios:
            scenario_name = str(scenario.get("name", scenario.get("kind", "fault")))
            result_json = dataset_dir / f"{scenario_name}.json"
            result_png = (
                dataset_dir / f"{scenario_name}.png" if generate_plots else None
            )
            payload = (
                json.loads(result_json.read_text(encoding="utf-8"))
                if reuse_existing and result_json.exists()
                else run_own_branch(
                    BranchConfig(
                        branch="own",
                        own_profile="package",
                        own_data_source="registry",
                        own_dataset_key=dataset_key,
                        own_data_dir=spec["dataset_dir"],
                        own_fault_injection=scenario,
                        show=False,
                        write_outputs=False,
                        output_json=str(result_json),
                        output_png=(
                            None if result_png is None else str(result_png)
                        ),
                    )
                )
            )
            evaluation = evaluate_stress_result(
                payload,
                baseline_payload=baseline,
            )
            evaluation["result_json"] = str(result_json)
            evaluation["trajectory_png"] = (
                None if result_png is None else str(result_png)
            )
            scenario_results[scenario_name] = evaluation
            flat_rows.append(_flat_row(dataset_key, evaluation))
        datasets[dataset_key] = {
            "baseline": evaluate_baseline_health(baseline),
            "baseline_result_json": str(baseline_json),
            "scenarios": scenario_results,
        }

    scenario_count = len(flat_rows)
    detected_count = sum(bool(row["anomaly_detected"]) for row in flat_rows)
    recovered_count = sum(
        row["recovery_delay_steps"] is not None for row in flat_rows
    )
    reconverged_count = sum(bool(row["final_reconverged"]) for row in flat_rows)
    false_recovery_count = sum(bool(row["false_recovery"]) for row in flat_rows)
    required_rows = [row for row in flat_rows if row["detection_required"]]
    required_detected_count = sum(
        bool(row["anomaly_detected"]) for row in required_rows
    )
    report = {
        "format_version": "1.0",
        "description": (
            "Deterministic localization fault-injection and recovery benchmark"
        ),
        "configuration": {
            "dataset_keys": keys,
            "generate_plots": bool(generate_plots),
            "reused_existing_results": bool(reuse_existing),
            "scenarios": fault_scenarios,
            "normal_positioning_affected": False,
        },
        "datasets": datasets,
        "aggregate": {
            "scenario_count": scenario_count,
            "anomaly_detected_count": detected_count,
            "anomaly_detection_rate": (
                None if scenario_count == 0 else detected_count / scenario_count
            ),
            "recovered_count": recovered_count,
            "recovery_rate": (
                None if scenario_count == 0 else recovered_count / scenario_count
            ),
            "final_reconverged_count": reconverged_count,
            "final_reconvergence_rate": (
                None if scenario_count == 0 else reconverged_count / scenario_count
            ),
            "false_recovery_count": false_recovery_count,
            "detection_required_count": len(required_rows),
            "required_anomaly_detected_count": required_detected_count,
            "required_anomaly_detection_rate": (
                None
                if not required_rows
                else required_detected_count / len(required_rows)
            ),
            "benchmark_pass_count": sum(
                bool(row["benchmark_passed"]) for row in flat_rows
            ),
            "baseline_false_recovery_count": sum(
                int(item["baseline"]["false_recovery_event_count"])
                for item in datasets.values()
            ),
        },
    }
    summary_json = output_root / "summary.json"
    summary_csv = output_root / "summary.csv"
    summary_markdown = output_root / "summary.md"
    report["output_json"] = str(summary_json)
    report["output_csv"] = str(summary_csv)
    report["output_markdown"] = str(summary_markdown)
    summary_json.write_text(
        json.dumps(report, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    with summary_csv.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(flat_rows[0]))
        writer.writeheader()
        writer.writerows(flat_rows)
    summary_markdown.write_text(_markdown_report(report), encoding="utf-8")
    return report


def print_stress_summary(report):
    aggregate = report["aggregate"]
    print(
        "Localization stress benchmark: "
        f"{aggregate['anomaly_detected_count']}/{aggregate['scenario_count']} "
        "faults detected, "
        f"{aggregate['final_reconverged_count']}/"
        f"{aggregate['scenario_count']} finally reconverged"
    )
    for dataset_key, dataset in report["datasets"].items():
        baseline = dataset["baseline"]
        print(
            f"- {dataset_key} baseline: warnings="
            f"{baseline['warning_step_count']}, false_recoveries="
            f"{baseline['false_recovery_event_count']}"
        )
        for name, result in dataset["scenarios"].items():
            print(
                f"  - {name}: detected={result['anomaly_detected']}, "
                f"warning_delay={result['warning_delay_steps']}, "
                f"recovery_delay={result['recovery_delay_steps']}, "
                f"final_reconverged={result['final_reconverged']}"
            )
    print(f"Saved JSON: {report['output_json']}")
    print(f"Saved CSV: {report['output_csv']}")
    print(f"Saved Markdown: {report['output_markdown']}")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Inject deterministic sensor faults and evaluate localization "
            "detection/recovery."
        )
    )
    parser.add_argument(
        "datasets",
        nargs="*",
        help="Evaluable own-data keys; defaults to manifest primary captures.",
    )
    parser.add_argument(
        "--scenario",
        action="append",
        choices=[item["name"] for item in DEFAULT_FAULT_SCENARIOS],
        help="Run only the selected scenario; repeat for multiple scenarios.",
    )
    parser.add_argument("--output-dir", default="results/localization_stress")
    parser.add_argument(
        "--plots",
        action="store_true",
        help="Also generate a trajectory and diagnostics PNG for every run.",
    )
    parser.add_argument(
        "--reuse-existing",
        action="store_true",
        help="Rebuild summary files from matching existing per-run JSON files.",
    )
    args = parser.parse_args(argv)
    selected = None
    if args.scenario:
        names = set(args.scenario)
        selected = [
            item for item in default_fault_scenarios() if item["name"] in names
        ]
    report = run_stress_benchmark(
        dataset_keys=args.datasets or None,
        scenarios=selected,
        output_dir=args.output_dir,
        generate_plots=args.plots,
        reuse_existing=args.reuse_existing,
    )
    print_stress_summary(report)
    return report


if __name__ == "__main__":
    main()
