"""Which areas a reading call to a service reads inside (see rules.py)."""

from service_reads import drive_lists, list_files, rclone_reads, rules

__all__ = ["drive_lists", "list_files", "rclone_reads", "rules"]
