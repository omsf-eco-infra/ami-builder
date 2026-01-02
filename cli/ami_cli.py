import sys
from datetime import date

import boto3
import botocore
import click

MANAGED_BY_VALUE = "omsf-ami-builder"


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
        return date.fromisoformat(value)
    except ValueError:
        return None


def collect_snapshot_ids(image):
    snapshot_ids = []
    for mapping in image.get("BlockDeviceMappings", []):
        ebs = mapping.get("Ebs")
        if ebs and ebs.get("SnapshotId"):
            snapshot_ids.append(ebs["SnapshotId"])
    return snapshot_ids


def format_image_line(image):
    tags = tags_to_dict(image)
    delete_after = tags.get("delete-after", "-")
    name = image.get("Name", "-")
    return f"{image['ImageId']}\t{name}\tdelete-after={delete_after}"


def delete_image(client, image, delete_snapshots=False):
    image_id = image["ImageId"]
    click.echo(f"Deregistering {image_id}")
    client.deregister_image(ImageId=image_id)

    if not delete_snapshots:
        return

    snapshot_ids = collect_snapshot_ids(image)
    for snapshot_id in snapshot_ids:
        click.echo(f"Deleting snapshot {snapshot_id}")
        try:
            client.delete_snapshot(SnapshotId=snapshot_id)
        except botocore.exceptions.ClientError as exc:  # pragma: no cover
            click.echo(f"Failed to delete snapshot {snapshot_id}: {exc}", err=True)


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
    today = date.today()

    expired = []
    for image in images:
        delete_after = parse_delete_after(tags_to_dict(image))
        if delete_after and delete_after < today:
            expired.append((delete_after, image))

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
    today = date.today()

    targets = []
    for image in images:
        delete_after = parse_delete_after(tags_to_dict(image))
        if delete_after and delete_after < today:
            targets.append((delete_after, image))

    if not targets:
        click.echo("No AMIs have expired delete-after dates.")
        return

    click.echo("The following AMIs will be deleted (snapshots included):")
    for delete_after, image in sorted(targets, key=lambda item: item[0]):
        click.echo(format_image_line(image))

    if not force:
        click.confirm("Proceed with deletion?", abort=True)

    for _, image in targets:
        delete_image(client, image, delete_snapshots=True)


if __name__ == "__main__":  # pragma: no cover
    cli()
