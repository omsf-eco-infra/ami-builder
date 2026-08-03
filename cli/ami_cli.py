import sys
import datetime as dt
from typing import Optional

import boto3
import botocore
import click

MANAGED_BY_VALUE = "omsf-ami-builder"
# Must match build-ami.pkr.hcl `run_tags.Name` prefix.
FAILED_BUILD_NAME_PREFIX = "ami-builder-"


def tags_to_dict(resource):
    return {tag["Key"]: tag["Value"] for tag in resource.get("Tags", [])}


def fetch_managed_images(client):
    response = client.describe_images(
        Owners=["self"],
        Filters=[
            {"Name": "tag:managed_by", "Values": [MANAGED_BY_VALUE]},
        ],
    )
    return response.get("Images", [])


def parse_delete_after(tags):
    value = tags.get("delete-after")
    if not value:  # pragma: no cover
        return None

    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        return None


def is_failed_build_image(image):
    """Return whether an AMI retained Packer's temporary builder name tag."""
    name = tags_to_dict(image).get("Name", "")
    return name.startswith(FAILED_BUILD_NAME_PREFIX)


def collect_snapshot_ids(image):
    snapshot_ids = []
    for mapping in image.get("BlockDeviceMappings", []):
        ebs = mapping.get("Ebs")
        if ebs and ebs.get("SnapshotId"):
            snapshot_ids.append(ebs["SnapshotId"])
    return snapshot_ids


def get_expired_images(images, today):
    """
    Filter images to those with delete-after tags before the given date.
    
    Parameters
    ----------
    images : list
        List of image dictionaries from AWS EC2 describe_images response.
    today : date
        date object representing the current date for comparison.
    
    Returns
    -------
    list of tuple
        List of tuples (delete_after_date, image) for images that have expired.
    """
    expired = []
    for image in images:
        delete_after = parse_delete_after(tags_to_dict(image))
        if delete_after and delete_after < today:
            expired.append((delete_after, image))
    return expired


def format_image_line(image):
    tags = tags_to_dict(image)
    delete_after = tags.get("delete-after", "-")
    name = image.get("Name", "-")
    return f"{image['ImageId']}\t{name}\tdelete-after={delete_after}"


def delete_image(client, image, delete_snapshots=True):
    image_id = image["ImageId"]
    click.echo(f"Deregistering {image_id}")
    try:
        client.deregister_image(ImageId=image_id)
    except Exception as exc:
        raise click.ClickException(
            f"Failed to deregister {image_id}: {exc}"
        ) from exc

    if not delete_snapshots:
        return

    snapshot_ids = collect_snapshot_ids(image)
    for snapshot_id in snapshot_ids:
        click.echo(f"Deleting snapshot {snapshot_id}")
        try:
            client.delete_snapshot(SnapshotId=snapshot_id)
        except botocore.exceptions.ClientError as exc:  # pragma: no cover
            click.echo(f"Failed to delete snapshot {snapshot_id}: {exc}", err=True)


def _utc_today() -> dt.date:
    # separate function for easier mocking
    return dt.datetime.now(dt.timezone.utc).date()


def _parse_date(value: str) -> dt.date:
    try:
        return dt.date.fromisoformat(value)
    except ValueError as exc:
        raise click.ClickException(
            f"Invalid date '{value}'. Use YYYY-MM-DD."
        ) from exc


def _resolve_delete_after(
    *,
    days: Optional[int],
    delete_after: Optional[str],
) -> tuple[Optional[dt.date], str]:
    if days is not None and delete_after:
        raise click.ClickException("Use only one of --days or --delete-after.")

    if delete_after:
        date_value = _parse_date(delete_after)
        return date_value, date_value.isoformat()

    if days is not None:
        if days < 0:
            raise click.ClickException("--days must be non-negative.")
        date_value = _utc_today() + dt.timedelta(days=days)
        return date_value, date_value.isoformat()

    raise click.ClickException("Provide --days or --delete-after.")


def _should_raise_exception(exc: botocore.exceptions.ClientError, dry_run: bool) -> bool:
    if not dry_run:
        return True
    code = exc.response.get("Error", {}).get("Code")
    return code != "DryRunOperation"


def _set_tags(ec2, ami_id: str, tags: dict, dry_run: bool) -> None:
    payload = [{"Key": key, "Value": value} for key, value in tags.items()]
    try:
        ec2.create_tags(
            Resources=[ami_id],
            Tags=payload,
            DryRun=dry_run,
        )
    except botocore.exceptions.ClientError as exc:
        if _should_raise_exception(exc, dry_run):
            raise


def _set_visibility(ec2, ami_id: str, public: bool, dry_run: bool) -> None:
    try:
        if public:
            ec2.modify_image_attribute(
                ImageId=ami_id,
                LaunchPermission={"Add": [{"Group": "all"}]},
                DryRun=dry_run,
            )
            return

        ec2.modify_image_attribute(
            ImageId=ami_id,
            LaunchPermission={"Remove": [{"Group": "all"}]},
            DryRun=dry_run,
        )
    except botocore.exceptions.ClientError as exc:
        if _should_raise_exception(exc, dry_run):
            raise


def _ensure_image(ec2, ami_id: str, dry_run: bool) -> None:
    try:
        response = ec2.describe_images(ImageIds=[ami_id], DryRun=dry_run)
    except botocore.exceptions.ClientError as exc:
        if _should_raise_exception(exc, dry_run):
            raise
        return
    images = response.get("Images", [])
    if not images:
        raise click.ClickException(f"AMI not found: {ami_id}")


def _parse_creation_date(image) -> Optional[dt.date]:
    value = image.get("CreationDate")
    if not value:
        return None
    if len(value) >= 10:
        try:
            return dt.date.fromisoformat(value[:10])
        except ValueError:
            return None
    return None


def _is_public_status(status: Optional[str]) -> bool:
    return status in ("public", "blessed")


def _should_publish(images, today: dt.date) -> bool:
    for image in images:
        tags = tags_to_dict(image)
        status = tags.get("status")
        if not _is_public_status(status):
            continue
        created = _parse_creation_date(image)
        if created and created.year == today.year and created.month == today.month:
            return False
    return True


def _should_bless(today: dt.date, should_publish: bool) -> bool:
    return should_publish and today.month == 6


def _apply_modify_state(
    *,
    ec2,
    ami_id: str,
    public: bool,
    days: Optional[int],
    delete_after: Optional[str],
    status: str,
    dry_run: bool,
) -> None:
    if public is None:
        raise click.ClickException("Choose either --public or --private.")

    _ensure_image(ec2, ami_id, dry_run)
    delete_after_date, delete_after_value = _resolve_delete_after(
        days=days,
        delete_after=delete_after,
    )

    if status in ("public", "blessed") and not public:
        raise click.ClickException(f"status '{status}' requires --public.")

    if status == "blessed":
        today = _utc_today()
        try:
            min_date = today.replace(year=today.year + 2)
        except ValueError:
            min_date = today.replace(year=today.year + 2, day=28)
        if delete_after_date is None or delete_after_date < min_date:
            raise click.ClickException(
                "status 'blessed' requires a delete-after at least 2 years from today."
            )

    _set_visibility(ec2, ami_id, public=public, dry_run=dry_run)
    _set_tags(
        ec2,
        ami_id,
        {
            "status": status,
            "delete-after": delete_after_value,
        },
        dry_run,
    )
    visibility = "public" if public else "private"
    click.echo(
        f"Updated {ami_id}: visibility={visibility} status={status} delete-after={delete_after_value}"
    )


@click.group()
def cli():
    """Manage AMIs created by omsf-ami-builder."""


@cli.command("list")
def list_managed_images():
    """List AMIs tagged with managed_by=omsf-ami-builder."""
    client = boto3.client("ec2")
    images = fetch_managed_images(client)
    if not images:
        click.echo("No AMIs found.")
        return

    click.echo("AMI ID\tName\tdelete-after")
    for image in sorted(images, key=lambda i: i.get("Name", "")):
        click.echo(format_image_line(image))


@cli.command("list-expired")
def list_expired():
    """List managed AMIs whose delete-after tag is before today."""
    client = boto3.client("ec2")
    images = fetch_managed_images(client)
    today = _utc_today()

    expired = get_expired_images(images, today)

    if not expired:
        click.echo("No AMIs have expired delete-after dates.")
        return

    click.echo("AMI ID\tName\tdelete-after")
    for delete_after, image in sorted(expired, key=lambda item: item[0]):
        click.echo(format_image_line(image))


@cli.command("delete")
@click.argument("image_ids", nargs=-1, required=True)
@click.option(
    "--delete-snapshots/--no-delete-snapshots",
    default=True,
    show_default=True,
    help="Delete EBS snapshots referenced by the AMI.",
)
def delete_images(image_ids, delete_snapshots):
    """Delete AMIs by ID."""
    client = boto3.client("ec2")
    try:
        response = client.describe_images(ImageIds=list(image_ids))
    except botocore.exceptions.ClientError as exc:  # pragma: no cover
        click.echo(f"Failed to describe AMIs: {exc}", err=True)
        sys.exit(1)

    images = response.get("Images", [])
    if not images:
        click.echo("No matching AMIs found.")
        return

    for image in images:
        delete_image(client, image, delete_snapshots=delete_snapshots)


@cli.command("auto-delete")
@click.option("--force", is_flag=True, help="Delete without asking for confirmation.")
def auto_delete(force):
    """
    Delete managed AMIs whose delete-after tag is before today.
    """

    client = boto3.client("ec2")
    images = fetch_managed_images(client)
    today = _utc_today()

    targets = get_expired_images(images, today)

    if not targets:
        click.echo("No AMIs have expired delete-after dates.")
        return

    click.echo("The following AMIs will be deleted (snapshots included):")
    for delete_after, image in sorted(targets, key=lambda item: item[0]):
        click.echo(format_image_line(image))

    if not force:
        click.confirm("Proceed with deletion?", abort=True)

    for _, image in sorted(targets, key=lambda item: item[0]):
        if is_failed_build_image(image):
            tags = tags_to_dict(image)
            click.echo(
                "WARNING: Cleaning up AMI "
                f"{image['ImageId']} ({tags['Name']}) from a failed Packer build.",
                err=True,
            )
        delete_image(client, image, delete_snapshots=True)


@cli.command("modify-state")
@click.argument("ami_id")
@click.option("--region", default=None, help="AWS region (defaults to AWS config).")
@click.option("--profile", default=None, help="AWS profile (defaults to AWS config).")
@click.option("--dry-run", is_flag=True, help="Validate changes without applying them.")
@click.option(
    "--public/--private",
    default=None,
    help="Set AMI visibility.",
)
@click.option(
    "--days",
    type=int,
    default=None,
    help="Retention in days (required unless --delete-after is set).",
)
@click.option(
    "--delete-after",
    default=None,
    help="Delete-after tag (YYYY-MM-DD).",
)
@click.option(
    "--status",
    type=click.Choice(("ephemeral", "public", "blessed", "other")),
    default="ephemeral",
    show_default=True,
    help="Status tag to set on the AMI.",
)
def modify_state(ami_id, region, profile, dry_run, public, days, delete_after, status):
    """Update AMI visibility and lifecycle tags."""
    session = boto3.Session(profile_name=profile, region_name=region)
    ec2 = session.client("ec2")

    _apply_modify_state(
        ec2=ec2,
        ami_id=ami_id,
        public=public,
        days=days,
        delete_after=delete_after,
        status=status,
        dry_run=dry_run,
    )


@cli.command("bless")
@click.argument("ami_id")
@click.option("--region", default=None, help="AWS region (defaults to AWS config).")
@click.option("--profile", default=None, help="AWS profile (defaults to AWS config).")
@click.option("--dry-run", is_flag=True, help="Validate changes without applying them.")
def bless(ami_id, region, profile, dry_run):
    """Mark an AMI as blessed and public with a 5-year retention."""
    session = boto3.Session(profile_name=profile, region_name=region)
    ec2 = session.client("ec2")
    _apply_modify_state(
        ec2=ec2,
        ami_id=ami_id,
        public=True,
        days=365 * 5,
        delete_after=None,
        status="blessed",
        dry_run=dry_run,
    )


@cli.command("publish")
@click.argument("ami_id")
@click.option("--region", default=None, help="AWS region (defaults to AWS config).")
@click.option("--profile", default=None, help="AWS profile (defaults to AWS config).")
@click.option("--dry-run", is_flag=True, help="Validate changes without applying them.")
def publish(ami_id, region, profile, dry_run):
    """Mark an AMI as public with a 366-day retention."""
    session = boto3.Session(profile_name=profile, region_name=region)
    ec2 = session.client("ec2")
    _apply_modify_state(
        ec2=ec2,
        ami_id=ami_id,
        public=True,
        days=366,
        delete_after=None,
        status="public",
        dry_run=dry_run,
    )


@cli.command("recommend-state")
@click.option("--region", default=None, help="AWS region (defaults to AWS config).")
@click.option("--profile", default=None, help="AWS profile (defaults to AWS config).")
def recommend_state(region, profile):
    """Recommend whether a new AMI should be published, blessed, or left ephemeral."""
    session = boto3.Session(profile_name=profile, region_name=region)
    client = session.client("ec2")
    images = fetch_managed_images(client)
    today = _utc_today()
    should_publish = _should_publish(images, today)
    if _should_bless(today, should_publish):
        click.echo("bless")
    elif should_publish:
        click.echo("publish")
    else:
        click.echo("leave ephemeral")


if __name__ == "__main__":  # pragma: no cover
    cli()
