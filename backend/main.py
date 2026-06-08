"""
main.py  ←  CLI entry point (no HTTP server)

Runs a default linear pipeline (checkout → setup → install → test → deploy)
straight from env vars, using the same compiler the API uses.

    python main.py
"""

import config
from payload_generator import compile_workflow, generate_shell_script
from docker_runner import run_in_container


def _default_graph(framework: str, target: str):
    """A simple linear DAG mirroring the original monolith's behaviour."""
    nodes = [
        {"id": "n1", "type": "checkout", "data": {}},
        {"id": "n2", "type": "setup-node", "data": {"nodeVersion": "20"}},
        {"id": "n3", "type": "install", "data": {}},
        {"id": "n4", "type": "test", "data": {"framework": framework}},
        {"id": "n5", "type": "deploy", "data": {"target": target}},
    ]
    edges = [
        {"source": "n1", "target": "n2"},
        {"source": "n2", "target": "n3"},
        {"source": "n3", "target": "n4"},
        {"source": "n4", "target": "n5"},
    ]
    return nodes, edges


def main() -> None:
    config.validate_required()

    framework, target = "playwright", "vercel"
    nodes, edges = _default_graph(framework, target)

    print(f"[main] Repo  : {config.REPO_URL}")
    print(f"[main] Branch: {config.BRANCH}")
    print(f"[main] Image : {config.DOCKER_IMAGE}\n")

    ci_yml = compile_workflow(
        nodes, edges,
        testing_framework=framework,
        deployment_target=target,
    )

    shell_script = generate_shell_script(
        repo_url=config.REPO_URL,
        branch=config.BRANCH,
        container_clone_dir=config.CONTAINER_CLONE_DIR,
        ci_yml_content=ci_yml,
        testing_framework=framework,
    )

    logs = run_in_container(
        shell_script=shell_script,
        access_token=config.GIT_TOKEN,
        image=config.DOCKER_IMAGE,
        timeout=config.CONTAINER_TIMEOUT,
        stream_to_stdout=True,
    )

    print("\n=== CONTAINER LOGS ===")
    print(logs)
    print("[main] Done.")


if __name__ == "__main__":
    main()