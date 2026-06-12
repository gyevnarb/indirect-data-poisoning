"""Perform experimental interventions on datasets following configured parameters.

The environment variables DATA_ID and CONDITION_ID must be set to enable interventions.
Optionally, the INTERVENTION_CONFIG_PATH environment variable can be set to specify a
custom path for the intervention configuration file.

The intervention config is stored at ~/.interventions.json or a user-specified path and
should contain a JSON object with the following structure:
{
    <dataset_id_or_project_id: str>: {
        <condition_id: int>: {
            <intervention_condition: str>: <value: bool>
        }
    }
}
"""

import json
import os
import shutil
from pathlib import Path

from datasets.utils import console


class Intervention:
    """Class to perform interventions on datasets or metadata."""

    def __init__(self) -> None:
        """Initialize the Intervention class by loading configuration from file."""
        self.data_id = os.getenv("DATA_ID")
        self.condition_id = os.getenv("CONDITION_ID")
        if self.condition_id is not None:
            self.condition_id = int(self.condition_id)

        if os.getenv("INTERVENTION_CONFIG_PATH"):
            self._config_path = Path(os.getenv("INTERVENTION_CONFIG_PATH"))
        else:
            self._config_path = Path.home() / "interventions.json"

        if os.getenv("EXPERIMENTS_CONFIG_PATH"):
            self._experiments_config_path = Path(os.getenv("EXPERIMENTS_CONFIG_PATH"))
        else:
            self._experiments_config_path = Path.home() / "experiments.json"

        self.enabled = False
        try:
            self.intervention = (
                json.load(self._config_path.open("r", encoding="utf-8"))
                if self._config_path.exists()
                else {}
            )[self.data_id][str(self.condition_id)]
            self.experiment = (
                json.load(self._experiments_config_path.open("r", encoding="utf-8"))
                if self._experiments_config_path.exists()
                else {}
            )[self.data_id]
        except (KeyError, json.JSONDecodeError):
            self.intervention = {}
            self.experiment = {}

    def enable(self, identifier: str) -> None:
        """Enable interventions based on a condition string."""
        if self.data_id is None or self.condition_id is None:
            self.enabled = False
        else:
            self.enabled = self.data_id == identifier

    # --- Replacement properties for interventions ---

    @property
    def replace_creator(self) -> dict[str, str]:
        """Whether to replace creator information for interventions."""
        return self.intervention.get("replace_creator", {}) if self.enabled else {}

    # --- Addition properties for interventions ---

    @property
    def add_readme_str(self) -> str:
        """The README content to add for interventions."""
        if not self.enabled:
            return ""
        complexity = str(self.intervention.get("add_readme_complexity", 0))
        return self.experiment.get("readmes", {}).get(complexity, "")

    @property
    def add_description_str(self) -> str:
        """The description to add for interventions.

        The description complexity can be configured in interventions.json.
        The actual descriptions are contained in the experiments.json file.
        """
        if not self.enabled:
            return ""
        complexity = str(self.intervention.get("add_description_complexity", 0))
        return self.experiment.get("descriptions", {}).get(complexity, "")

    @property
    def add_agent_instructions_str(self) -> str:
        """The agent instructions to add for interventions."""
        if not self.enabled:
            return ""
        complexity = str(self.intervention.get("add_agent_instructions_complexity", 0))
        return self.experiment.get("agent_instructions", {}).get(complexity, "")

    @property
    def add_tags(self) -> list[str]:
        """The tags to add for interventions."""
        return self.experiment.get("tags", []) if self.enabled else []

    @property
    def add_pdf_path(self) -> str:
        """The path to the PDF paper to copy for interventions."""
        if not self.enabled:
            return ""
        complexity = str(self.intervention.get("add_paper_complexity", 0))
        return self.experiment.get("papers", {}).get(complexity, "")

    @property
    def add_script_path(self) -> str:
        """The path to a data loading script to add for interventions."""
        if not self.enabled:
            return ""
        complexity = str(self.intervention.get("add_script_complexity", 0))
        return self.experiment.get("scripts", {}).get(complexity, "")

    def copy_files(
        self,
        project_dir: Path,
        override: bool,
        cnt: int,
        skp: int,
    ) -> tuple[int, int]:
        """Copy files for interventions."""

        def _write_text(
            content: str, destination: Path, s: int, c: int,
        ) -> tuple[int, int]:
            if not override and destination.exists():
                console.print(
                    f"[yellow]Skipping existing file: {destination}[/yellow]",
                )
                s += 1
            else:
                with destination.open("w", encoding="utf-8") as f:
                    f.write(content)
                    console.print(f"[green]Downloading: {destination}[/green]")
                    c += 1
            return s, c

        def _copy_file(source: Path, s: int, c: int) -> tuple[int, int]:
            destination = project_dir / source.name
            if source.exists() and source.is_file():
                if not override and destination.exists():
                    console.print(
                        f"[yellow]Skipping existing file: {destination}[/yellow]",
                    )
                    s += 1
                else:
                    shutil.copy2(source, destination)
                    console.print(f"[green]Downloading: {destination}[/green]")
                    c += 1
            return s, c

        if not self.enabled:
            return cnt, skp

        if self.add_readme_str:
            skp, cnt = _write_text(
                self.add_readme_str, project_dir / "README.md", skp, cnt,
            )
        if self.add_agent_instructions_str:
            skp, cnt = _write_text(
                self.add_agent_instructions_str, project_dir / "AGENTS.md", skp, cnt,
            )
        if self.add_pdf_path:
            skp, cnt = _copy_file(Path(self.add_pdf_path), skp, cnt)
        if self.add_script_path:
            skp, cnt = _copy_file(Path(self.add_script_path), skp, cnt)

        return cnt, skp

    # --- Removal properties for interventions ---

    @property
    def remove_creators(self) -> bool:
        """Whether to remove creator information for interventions."""
        return self.enabled and self.intervention.get("remove_creators", False)

    @property
    def remove_provenance(self) -> bool:
        """Whether to remove provenance information for interventions."""
        return self.enabled and self.intervention.get("remove_provenance", False)

    @property
    def remove_metadata(self) -> bool:
        """Whether to remove metadata for interventions."""
        return self.enabled and self.intervention.get("remove_metadata", False)

    @property
    def remove_version_history(self) -> bool:
        """Whether to remove version history for interventions."""
        return self.enabled and self.intervention.get("remove_version_history", False)

    @property
    def remove_metrics(self) -> bool:
        """Whether to remove metrics for interventions."""
        return self.enabled and self.intervention.get("remove_metrics", False)

    @property
    def remove_link_text(self) -> str:
        """The text to remove from the description containing links."""
        return self.intervention.get("remove_link_text", "") if self.enabled else ""

    @property
    def remove_sha256(self) -> bool:
        """Whether to remove SHA256 checksums for interventions."""
        return self.enabled and self.intervention.get("remove_sha256", False)


IV = Intervention()
