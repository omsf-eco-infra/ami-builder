from datetime import date

import boto3
import botocore
import pytest
from click.testing import CliRunner
from moto import mock_aws

import ami_cli


@pytest.fixture(autouse=True)
def set_region(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    # Force dummy credentials so no real AWS calls are made even if moto is absent.
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")


def fixed_date(year=2024, month=1, day=1):
    class _FixedDate(date):
        @classmethod
        def today(cls):
            return cls(year, month, day)

    return _FixedDate


def get_image_snapshot_ids(ec2, image_id):
    images = ec2.describe_images(ImageIds=[image_id])["Images"]
    if not images:
        return []
    snapshot_ids = []
    for mapping in images[0].get("BlockDeviceMappings", []):
        ebs = mapping.get("Ebs")
        if ebs and ebs.get("SnapshotId"):
            snapshot_ids.append(ebs["SnapshotId"])
    return snapshot_ids


def create_managed_ami(ec2, name, delete_after=None, with_snapshot=True):
    block_mappings = []

    if with_snapshot:
        volume = ec2.create_volume(AvailabilityZone="us-east-1a", Size=8)
        snapshot = ec2.create_snapshot(VolumeId=volume["VolumeId"], Description="test")
        block_mappings.append(
            {
                "DeviceName": "/dev/xvda",
                "Ebs": {
                    "SnapshotId": snapshot["SnapshotId"],
                },
            }
        )

    image = ec2.register_image(
        Name=name,
        RootDeviceName="/dev/xvda",
        BlockDeviceMappings=block_mappings or None,
    )
    tags = [{"Key": "managed_by", "Value": ami_cli.MANAGED_BY_VALUE}]
    if delete_after:
        tags.append({"Key": "delete-after", "Value": delete_after})
    ec2.create_tags(Resources=[image["ImageId"]], Tags=tags)
    snapshots = get_image_snapshot_ids(ec2, image["ImageId"])
    return image["ImageId"], snapshots


def assert_snapshot_missing(ec2, snapshot_id):
    try:
        ec2.describe_snapshots(SnapshotIds=[snapshot_id])
    except botocore.exceptions.ClientError:
        return
    assert snapshot_id not in {
        snap["SnapshotId"] for snap in ec2.describe_snapshots(OwnerIds=["self"])["Snapshots"]
    }


def assert_snapshot_exists(ec2, snapshot_id):
    assert snapshot_id in {
        snap["SnapshotId"] for snap in ec2.describe_snapshots(OwnerIds=["self"])["Snapshots"]
    }


@mock_aws
def test_list_managed_images_shows_managed_only():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    ami_one, _ = create_managed_ami(ec2, "first")
    ami_two, _ = create_managed_ami(ec2, "second")

    # Unmanaged image should not be listed
    unmanaged = ec2.register_image(Name="unmanaged", RootDeviceName="/dev/xvda")
    ec2.create_tags(Resources=[unmanaged["ImageId"]], Tags=[{"Key": "other", "Value": "x"}])

    result = CliRunner().invoke(ami_cli.cli, ["list"])
    assert result.exit_code == 0
    assert "AMI ID\tName\tdelete-after" in result.output
    assert ami_one in result.output
    assert ami_two in result.output
    assert unmanaged["ImageId"] not in result.output


@mock_aws
def test_list_managed_images_handles_empty():
    result = CliRunner().invoke(ami_cli.cli, ["list"])
    assert result.exit_code == 0
    assert "No AMIs found." in result.output
    assert "AMI ID\tName\tdelete-after" not in result.output


@mock_aws
def test_list_expired_filters_by_past_delete_after(monkeypatch):
    monkeypatch.setattr(ami_cli, "date", fixed_date())
    ec2 = boto3.client("ec2", region_name="us-east-1")

    past_ami, _ = create_managed_ami(ec2, "past", delete_after="2023-12-31")
    create_managed_ami(ec2, "future", delete_after="2024-02-01")
    create_managed_ami(ec2, "invalid", delete_after="not-a-date")

    result = CliRunner().invoke(ami_cli.cli, ["list-expired"])
    assert result.exit_code == 0
    assert past_ami in result.output
    assert "future" not in result.output
    assert "invalid" not in result.output


@mock_aws
def test_list_expired_handles_no_expired(monkeypatch):
    monkeypatch.setattr(ami_cli, "date", fixed_date())
    ec2 = boto3.client("ec2", region_name="us-east-1")

    create_managed_ami(ec2, "future", delete_after="2024-02-01")
    create_managed_ami(ec2, "invalid", delete_after="not-a-date")

    result = CliRunner().invoke(ami_cli.cli, ["list-expired"])
    assert result.exit_code == 0
    assert "No AMIs have expired delete-after dates." in result.output
    assert "AMI ID\tName\tdelete-after" not in result.output


@mock_aws
def test_delete_images_removes_snapshots_by_default():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    ami_to_delete, snapshot_ids = create_managed_ami(ec2, "todelete")
    ami_to_keep, _ = create_managed_ami(ec2, "keep")

    result = CliRunner().invoke(ami_cli.cli, ["delete", ami_to_delete])
    assert result.exit_code == 0
    remaining = ec2.describe_images(Owners=["self"])["Images"]
    remaining_ids = {img["ImageId"] for img in remaining}
    assert ami_to_delete not in remaining_ids
    assert ami_to_keep in remaining_ids

    for snapshot_id in snapshot_ids:
        assert_snapshot_missing(ec2, snapshot_id)


@mock_aws
def test_delete_images_can_skip_snapshot_removal():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    ami_to_delete, snapshot_ids = create_managed_ami(ec2, "todelete")

    result = CliRunner().invoke(ami_cli.cli, ["delete", ami_to_delete, "--no-delete-snapshots"])
    assert result.exit_code == 0
    remaining_ids = {img["ImageId"] for img in ec2.describe_images(Owners=["self"])["Images"]}
    assert ami_to_delete not in remaining_ids

    for snapshot_id in snapshot_ids:
        assert_snapshot_exists(ec2, snapshot_id)


def test_delete_images_handles_empty_response(monkeypatch):
    class DummyClient:
        def describe_images(self, ImageIds):
            return {"Images": []}

    monkeypatch.setattr(ami_cli.boto3, "client", lambda service: DummyClient())

    result = CliRunner().invoke(ami_cli.cli, ["delete", "ami-12345678"])
    assert result.exit_code == 0
    assert "No matching AMIs found." in result.output


@mock_aws
def test_auto_delete_removes_expired_amis_and_snapshots(monkeypatch):
    monkeypatch.setattr(ami_cli, "date", fixed_date())
    ec2 = boto3.client("ec2", region_name="us-east-1")

    expired_one, snap_one = create_managed_ami(ec2, "expired-one", delete_after="2023-12-01")
    expired_two, snap_two = create_managed_ami(ec2, "expired-two", delete_after="2023-12-15")
    stay_id, _ = create_managed_ami(ec2, "stay", delete_after="2024-02-01")

    result = CliRunner().invoke(ami_cli.cli, ["auto-delete", "--force"])
    assert result.exit_code == 0
    remaining_ids = {img["ImageId"] for img in ec2.describe_images(Owners=["self"])["Images"]}
    assert stay_id in remaining_ids
    assert expired_one not in remaining_ids
    assert expired_two not in remaining_ids

    for snapshot_id in (*snap_one, *snap_two):
        assert_snapshot_missing(ec2, snapshot_id)


@mock_aws
def test_auto_delete_handles_no_targets(monkeypatch):
    monkeypatch.setattr(ami_cli, "date", fixed_date())
    ec2 = boto3.client("ec2", region_name="us-east-1")

    create_managed_ami(ec2, "future", delete_after="2024-02-01")

    result = CliRunner().invoke(ami_cli.cli, ["auto-delete", "--force"])
    assert result.exit_code == 0
    assert "No AMIs have expired delete-after dates." in result.output


@mock_aws
def test_auto_delete_prompts_without_force(monkeypatch):
    monkeypatch.setattr(ami_cli, "date", fixed_date())
    ec2 = boto3.client("ec2", region_name="us-east-1")

    expired_id, _ = create_managed_ami(ec2, "expired", delete_after="2023-12-01")
    stay_id, _ = create_managed_ami(ec2, "stay", delete_after="2024-02-01")

    result = CliRunner().invoke(ami_cli.cli, ["auto-delete"], input="y\n")
    assert result.exit_code == 0
    assert "Proceed with deletion?" in result.output

    remaining_ids = {img["ImageId"] for img in ec2.describe_images(Owners=["self"])["Images"]}
    assert stay_id in remaining_ids
    assert expired_id not in remaining_ids
