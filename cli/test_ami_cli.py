from datetime import date
import datetime as dt

import boto3
import botocore
import click
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
    }  # pragma: no cover  (defensive)


def assert_snapshot_exists(ec2, snapshot_id):
    assert snapshot_id in {
        snap["SnapshotId"] for snap in ec2.describe_snapshots(OwnerIds=["self"])["Snapshots"]
    }


def test_tags_to_dict_handles_missing_tags():
    assert ami_cli.tags_to_dict({}) == {}


def test_tags_to_dict_converts_tags_list():
    resource = {"Tags": [{"Key": "one", "Value": "1"}, {"Key": "two", "Value": "2"}]}
    assert ami_cli.tags_to_dict(resource) == {"one": "1", "two": "2"}


def test_parse_delete_after_handles_blank_and_invalid():
    assert ami_cli.parse_delete_after({}) is None
    assert ami_cli.parse_delete_after({"delete-after": "not-a-date"}) is None


def test_parse_delete_after_parses_iso_date():
    assert ami_cli.parse_delete_after({"delete-after": "2024-01-15"}) == date(2024, 1, 15)


def test_collect_snapshot_ids_handles_missing_data():
    assert ami_cli.collect_snapshot_ids({}) == []
    assert ami_cli.collect_snapshot_ids({"BlockDeviceMappings": [{"DeviceName": "/dev/xvda"}]}) == []


def test_collect_snapshot_ids_collects_snapshot_ids():
    image = {
        "BlockDeviceMappings": [
            {"Ebs": {"SnapshotId": "snap-1"}},
            {"Ebs": {"SnapshotId": "snap-2"}},
            {"DeviceName": "/dev/xvda"},
        ]
    }
    assert ami_cli.collect_snapshot_ids(image) == ["snap-1", "snap-2"]


def test_get_expired_images_returns_empty_for_no_expired():
    images = []
    today = date(2024, 1, 15)
    assert ami_cli.get_expired_images(images, today) == []


def test_get_expired_images_filters_by_date():
    images = [
        {"ImageId": "ami-1", "Tags": [{"Key": "delete-after", "Value": "2024-01-10"}]},
        {"ImageId": "ami-2", "Tags": [{"Key": "delete-after", "Value": "2024-01-20"}]},
        {"ImageId": "ami-3", "Tags": [{"Key": "delete-after", "Value": "2024-01-05"}]},
    ]
    today = date(2024, 1, 15)
    
    result = ami_cli.get_expired_images(images, today)
    
    assert len(result) == 2
    # Check that we got the right images (ami-1 and ami-3)
    result_image_ids = {img["ImageId"] for _, img in result}
    assert result_image_ids == {"ami-1", "ami-3"}
    # Check that the dates are correct
    assert result[0][0] in [date(2024, 1, 10), date(2024, 1, 5)]
    assert result[1][0] in [date(2024, 1, 10), date(2024, 1, 5)]


def test_get_expired_images_handles_missing_and_invalid_dates():
    images = [
        {"ImageId": "ami-1", "Tags": [{"Key": "delete-after", "Value": "2024-01-10"}]},
        {"ImageId": "ami-2", "Tags": [{"Key": "other", "Value": "value"}]},  # no delete-after
        {"ImageId": "ami-3", "Tags": [{"Key": "delete-after", "Value": "not-a-date"}]},  # invalid
        {"ImageId": "ami-4"},  # no tags at all
    ]
    today = date(2024, 1, 15)
    
    result = ami_cli.get_expired_images(images, today)
    
    assert len(result) == 1
    assert result[0][1]["ImageId"] == "ami-1"
    assert result[0][0] == date(2024, 1, 10)


def test_get_expired_images_excludes_future_dates():
    images = [
        {"ImageId": "ami-1", "Tags": [{"Key": "delete-after", "Value": "2024-01-20"}]},
        {"ImageId": "ami-2", "Tags": [{"Key": "delete-after", "Value": "2024-01-15"}]},  # equal to today
    ]
    today = date(2024, 1, 15)
    
    result = ami_cli.get_expired_images(images, today)
    
    # Both should be excluded (one is future, one is equal to today)
    assert len(result) == 0


def test_format_image_line_handles_missing_fields():
    assert ami_cli.format_image_line({"ImageId": "ami-1"}) == "ami-1\t-\tdelete-after=-"


def test_format_image_line_uses_tags_and_name():
    image = {
        "ImageId": "ami-2",
        "Name": "test-image",
        "Tags": [{"Key": "delete-after", "Value": "2024-02-01"}],
    }
    assert ami_cli.format_image_line(image) == "ami-2\ttest-image\tdelete-after=2024-02-01"


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
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 1, 1))
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
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 1, 1))
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


def test_delete_images_exits_when_deregister_fails(monkeypatch):
    class DummyClient:
        def __init__(self):
            self.delete_snapshot_called = False

        def describe_images(self, ImageIds):
            return {
                "Images": [
                    {
                        "ImageId": "ami-12345678",
                        "BlockDeviceMappings": [{"Ebs": {"SnapshotId": "snap-12345678"}}],
                    }
                ]
            }

        def deregister_image(self, ImageId):
            raise botocore.exceptions.ClientError(
                {"Error": {"Code": "UnauthorizedOperation", "Message": "no permission"}},
                "DeregisterImage",
            )

        def delete_snapshot(self, SnapshotId):
            self.delete_snapshot_called = True

    client = DummyClient()
    monkeypatch.setattr(ami_cli.boto3, "client", lambda service: client)

    result = CliRunner().invoke(ami_cli.cli, ["delete", "ami-12345678"])
    assert result.exit_code != 0
    assert "Failed to deregister ami-12345678" in result.output
    assert not client.delete_snapshot_called


@mock_aws
def test_auto_delete_removes_expired_amis_and_snapshots(monkeypatch):
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 1, 1))
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
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 1, 1))
    ec2 = boto3.client("ec2", region_name="us-east-1")

    create_managed_ami(ec2, "future", delete_after="2024-02-01")

    result = CliRunner().invoke(ami_cli.cli, ["auto-delete", "--force"])
    assert result.exit_code == 0
    assert "No AMIs have expired delete-after dates." in result.output


@mock_aws
def test_auto_delete_prompts_without_force(monkeypatch):
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 1, 1))
    ec2 = boto3.client("ec2", region_name="us-east-1")

    expired_id, _ = create_managed_ami(ec2, "expired", delete_after="2023-12-01")
    stay_id, _ = create_managed_ami(ec2, "stay", delete_after="2024-02-01")

    result = CliRunner().invoke(ami_cli.cli, ["auto-delete"], input="y\n")
    assert result.exit_code == 0
    assert "Proceed with deletion?" in result.output

    remaining_ids = {img["ImageId"] for img in ec2.describe_images(Owners=["self"])["Images"]}
    assert stay_id in remaining_ids
    assert expired_id not in remaining_ids


def test_utc_today_uses_utc_date(monkeypatch):
    class FixedDateTime(dt.datetime):
        @classmethod
        def now(cls, tz=None):
            return cls(2024, 2, 3, 4, 5, 6, tzinfo=dt.timezone.utc)

    monkeypatch.setattr(ami_cli.dt, "datetime", FixedDateTime)
    assert ami_cli._utc_today() == date(2024, 2, 3)


def test_parse_date_valid_and_invalid():
    assert ami_cli._parse_date("2024-03-10") == date(2024, 3, 10)
    with pytest.raises(click.ClickException):
        ami_cli._parse_date("not-a-date")


def test_resolve_delete_after_accepts_explicit_date_only():
    resolved_date, resolved_value = ami_cli._resolve_delete_after(
        days=None,
        delete_after="2024-05-01",
    )
    assert resolved_date == date(2024, 5, 1)
    assert resolved_value == "2024-05-01"


def test_resolve_delete_after_uses_days(monkeypatch):
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 1, 1))
    resolved_date, resolved_value = ami_cli._resolve_delete_after(
        days=30,
        delete_after=None,
    )
    assert resolved_date == date(2024, 1, 31)
    assert resolved_value == "2024-01-31"


def test_resolve_delete_after_requires_value():
    with pytest.raises(click.ClickException):
        ami_cli._resolve_delete_after(days=None, delete_after=None)


def test_resolve_delete_after_rejects_negative_days():
    with pytest.raises(click.ClickException):
        ami_cli._resolve_delete_after(days=-1, delete_after=None)


def test_resolve_delete_after_rejects_both_days_and_date():
    with pytest.raises(click.ClickException):
        ami_cli._resolve_delete_after(days=10, delete_after="2024-05-01")


def test_handle_dry_run_accepts_dry_run_error():
    exc = botocore.exceptions.ClientError(
        {"Error": {"Code": "DryRunOperation", "Message": "dry run"}},
        "CreateTags",
    )
    ami_cli._handle_dry_run(exc, dry_run=True)
    with pytest.raises(botocore.exceptions.ClientError):
        ami_cli._handle_dry_run(exc, dry_run=False)


def test_handle_dry_run_rejects_other_errors():
    exc = botocore.exceptions.ClientError(
        {"Error": {"Code": "UnauthorizedOperation", "Message": "nope"}},
        "CreateTags",
    )
    with pytest.raises(botocore.exceptions.ClientError):
        ami_cli._handle_dry_run(exc, dry_run=True)


@mock_aws
def test_set_tags_applies_tags():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "tag-test")
    ami_cli._set_tags(ec2, image_id, {"status": "public"}, dry_run=False)
    tags = ami_cli.tags_to_dict(ec2.describe_images(ImageIds=[image_id])["Images"][0])
    assert tags["status"] == "public"


@mock_aws
def test_set_tags_dry_run_does_not_error():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "tag-test")
    ami_cli._set_tags(ec2, image_id, {"status": "public"}, dry_run=True)


@mock_aws
def test_set_visibility_updates_launch_permissions():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "visibility-test")

    ami_cli._set_visibility(ec2, image_id, public=True, dry_run=False)
    attributes = ec2.describe_image_attribute(
        ImageId=image_id, Attribute="launchPermission"
    )
    groups = {perm.get("Group") for perm in attributes.get("LaunchPermissions", [])}
    assert "all" in groups

    ami_cli._set_visibility(ec2, image_id, public=False, dry_run=False)
    attributes = ec2.describe_image_attribute(
        ImageId=image_id, Attribute="launchPermission"
    )
    groups = {perm.get("Group") for perm in attributes.get("LaunchPermissions", [])}
    assert "all" not in groups


@mock_aws
def test_set_visibility_dry_run_does_not_error():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "visibility-test")
    ami_cli._set_visibility(ec2, image_id, public=True, dry_run=True)


def test_ensure_image_raises_on_missing():
    class DummyClient:
        def describe_images(self, ImageIds, DryRun=False):
            return {"Images": []}

    with pytest.raises(click.ClickException):
        ami_cli._ensure_image(DummyClient(), "ami-missing", dry_run=False)


@mock_aws
def test_ensure_image_passes_for_existing():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "exists")
    ami_cli._ensure_image(ec2, image_id, dry_run=False)


@mock_aws
def test_apply_modify_state_updates_tags_and_visibility():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "apply")

    ami_cli._apply_modify_state(
        ec2=ec2,
        ami_id=image_id,
        public=True,
        days=10,
        delete_after=None,
        status="public",
        dry_run=False,
    )

    tags = ami_cli.tags_to_dict(ec2.describe_images(ImageIds=[image_id])["Images"][0])
    assert tags["status"] == "public"
    assert tags["delete-after"]

    attributes = ec2.describe_image_attribute(
        ImageId=image_id, Attribute="launchPermission"
    )
    groups = {perm.get("Group") for perm in attributes.get("LaunchPermissions", [])}
    assert "all" in groups


def test_parse_creation_date_handles_missing_and_invalid():
    assert ami_cli._parse_creation_date({}) is None
    assert ami_cli._parse_creation_date({"CreationDate": "bad"}) is None


def test_parse_creation_date_parses_iso_prefix():
    image = {"CreationDate": "2024-02-03T04:05:06.000Z"}
    assert ami_cli._parse_creation_date(image) == date(2024, 2, 3)


def test_is_public_status_matches_expected():
    assert ami_cli._is_public_status("public")
    assert ami_cli._is_public_status("blessed")
    assert not ami_cli._is_public_status("ephemeral")
    assert not ami_cli._is_public_status(None)


def test_should_publish_when_no_public_images():
    today = date(2024, 5, 1)
    images = [
        {"CreationDate": "2024-05-01T00:00:00Z", "Tags": [{"Key": "status", "Value": "ephemeral"}]},
    ]
    assert ami_cli._should_publish(images, today)


def test_should_publish_false_when_public_exists_same_month():
    today = date(2024, 5, 10)
    images = [
        {"CreationDate": "2024-05-02T00:00:00Z", "Tags": [{"Key": "status", "Value": "public"}]},
    ]
    assert not ami_cli._should_publish(images, today)


def test_should_publish_false_when_blessed_exists_same_month():
    today = date(2024, 6, 10)
    images = [
        {"CreationDate": "2024-06-02T00:00:00Z", "Tags": [{"Key": "status", "Value": "blessed"}]},
    ]
    assert not ami_cli._should_publish(images, today)


def test_should_publish_true_when_public_is_previous_month():
    today = date(2024, 6, 10)
    images = [
        {"CreationDate": "2024-05-30T00:00:00Z", "Tags": [{"Key": "status", "Value": "public"}]},
    ]
    assert ami_cli._should_publish(images, today)


def test_should_bless_requires_june_and_publish():
    assert ami_cli._should_bless(date(2024, 6, 1), should_publish=True)
    assert not ami_cli._should_bless(date(2024, 6, 1), should_publish=False)
    assert not ami_cli._should_bless(date(2024, 5, 1), should_publish=True)


def test_recommend_state_outputs_bless(monkeypatch):
    images = []
    monkeypatch.setattr(ami_cli, "fetch_managed_images", lambda client: images)
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 6, 1))

    result = CliRunner().invoke(ami_cli.cli, ["recommend-state"])
    assert result.exit_code == 0
    assert result.output.strip() == "bless"


def test_recommend_state_outputs_publish(monkeypatch):
    images = []
    monkeypatch.setattr(ami_cli, "fetch_managed_images", lambda client: images)
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 5, 1))

    result = CliRunner().invoke(ami_cli.cli, ["recommend-state"])
    assert result.exit_code == 0
    assert result.output.strip() == "publish"


def test_recommend_state_outputs_leave_ephemeral(monkeypatch):
    images = [
        {"CreationDate": "2024-05-02T00:00:00Z", "Tags": [{"Key": "status", "Value": "public"}]},
    ]
    monkeypatch.setattr(ami_cli, "fetch_managed_images", lambda client: images)
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 5, 10))

    result = CliRunner().invoke(ami_cli.cli, ["recommend-state"])
    assert result.exit_code == 0
    assert result.output.strip() == "leave ephemeral"

@mock_aws
def test_modify_state_requires_visibility_flag():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "modify")

    result = CliRunner().invoke(
        ami_cli.cli,
        ["modify-state", image_id, "--days", "30"],
    )
    assert result.exit_code != 0
    assert "Choose either --public or --private." in result.output


@mock_aws
def test_modify_state_requires_delete_after_or_days():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "modify")

    result = CliRunner().invoke(
        ami_cli.cli,
        ["modify-state", image_id, "--public"],
    )
    assert result.exit_code != 0
    assert "Provide --days or --delete-after." in result.output


@mock_aws
def test_modify_state_public_updates_visibility_and_tags():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "modify")

    result = CliRunner().invoke(
        ami_cli.cli,
        ["modify-state", image_id, "--public", "--days", "365", "--status", "public"],
    )
    assert result.exit_code == 0
    tags = ami_cli.tags_to_dict(ec2.describe_images(ImageIds=[image_id])["Images"][0])
    assert tags["status"] == "public"
    assert tags["delete-after"]

    attributes = ec2.describe_image_attribute(
        ImageId=image_id, Attribute="launchPermission"
    )
    groups = {perm.get("Group") for perm in attributes.get("LaunchPermissions", [])}
    assert "all" in groups


@mock_aws
def test_modify_state_private_updates_visibility_and_tags():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "modify")

    result = CliRunner().invoke(
        ami_cli.cli,
        [
            "modify-state",
            image_id,
            "--private",
            "--delete-after",
            "2025-01-01",
            "--status",
            "ephemeral",
        ],
    )
    assert result.exit_code == 0
    tags = ami_cli.tags_to_dict(ec2.describe_images(ImageIds=[image_id])["Images"][0])
    assert tags["status"] == "ephemeral"
    assert tags["delete-after"] == "2025-01-01"

    attributes = ec2.describe_image_attribute(
        ImageId=image_id, Attribute="launchPermission"
    )
    groups = {perm.get("Group") for perm in attributes.get("LaunchPermissions", [])}
    assert "all" not in groups


@mock_aws
def test_modify_state_public_status_requires_public_flag():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "modify")

    result = CliRunner().invoke(
        ami_cli.cli,
        [
            "modify-state",
            image_id,
            "--private",
            "--days",
            "365",
            "--status",
            "public",
        ],
    )
    assert result.exit_code != 0
    assert "status 'public' requires --public." in result.output


@mock_aws
def test_modify_state_blessed_requires_public_flag():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "modify")

    result = CliRunner().invoke(
        ami_cli.cli,
        [
            "modify-state",
            image_id,
            "--private",
            "--days",
            "3650",
            "--status",
            "blessed",
        ],
    )
    assert result.exit_code != 0
    assert "status 'blessed' requires --public." in result.output


@mock_aws
def test_modify_state_blessed_requires_minimum_lifetime(monkeypatch):
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 1, 1))
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "modify")

    result = CliRunner().invoke(
        ami_cli.cli,
        [
            "modify-state",
            image_id,
            "--public",
            "--delete-after",
            "2025-12-31",
            "--status",
            "blessed",
        ],
    )
    assert result.exit_code != 0
    assert "status 'blessed' requires a delete-after at least 2 years from today." in result.output


@mock_aws
def test_modify_state_blessed_accepts_long_lifetime(monkeypatch):
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 1, 1))
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "modify")

    result = CliRunner().invoke(
        ami_cli.cli,
        [
            "modify-state",
            image_id,
            "--public",
            "--delete-after",
            "2026-01-01",
            "--status",
            "blessed",
        ],
    )
    assert result.exit_code == 0
    tags = ami_cli.tags_to_dict(ec2.describe_images(ImageIds=[image_id])["Images"][0])
    assert tags["status"] == "blessed"


@mock_aws
def test_bless_command_sets_five_year_retention(monkeypatch):
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 1, 1))
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "bless")

    result = CliRunner().invoke(ami_cli.cli, ["bless", image_id])
    assert result.exit_code == 0
    tags = ami_cli.tags_to_dict(ec2.describe_images(ImageIds=[image_id])["Images"][0])
    assert tags["status"] == "blessed"
    expected = (date(2024, 1, 1) + dt.timedelta(days=365 * 5)).isoformat()
    assert tags["delete-after"] == expected


@mock_aws
def test_publish_command_sets_retention(monkeypatch):
    monkeypatch.setattr(ami_cli, "_utc_today", lambda: date(2024, 1, 1))
    ec2 = boto3.client("ec2", region_name="us-east-1")
    image_id, _ = create_managed_ami(ec2, "publish")

    result = CliRunner().invoke(ami_cli.cli, ["publish", image_id])
    assert result.exit_code == 0
    tags = ami_cli.tags_to_dict(ec2.describe_images(ImageIds=[image_id])["Images"][0])
    assert tags["status"] == "public"
    expected = (date(2024, 1, 1) + dt.timedelta(days=366)).isoformat()
    assert tags["delete-after"] == expected
