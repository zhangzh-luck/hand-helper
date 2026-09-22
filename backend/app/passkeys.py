"""WebAuthn ceremonies for the application's single, local owner.

The browser exchanges JSON-safe base64url values. Cryptographic validation is
delegated to py_webauthn; this module persists only public credential material.
"""
from __future__ import annotations

import json
import secrets
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession
from webauthn import (
    base64url_to_bytes,
    generate_authentication_options,
    generate_registration_options,
    options_to_json,
    verify_authentication_response,
    verify_registration_response,
)
from webauthn.helpers import bytes_to_base64url
from webauthn.helpers.structs import (
    AttestationConveyancePreference,
    AuthenticatorSelectionCriteria,
    PublicKeyCredentialDescriptor,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

from app.config import Settings
from app.db_models import PasskeyChallenge, PasskeyCredential, PasskeyOwner


class PasskeyError(ValueError):
    pass


async def owner_for(db: AsyncSession) -> PasskeyOwner:
    owner = await db.get(PasskeyOwner, 1)
    if owner is None:
        owner = PasskeyOwner(id=1, user_handle=bytes_to_base64url(secrets.token_bytes(32)))
        db.add(owner)
        await db.commit()
        await db.refresh(owner)
    return owner


async def issue_challenge(db: AsyncSession, ceremony: str, settings: Settings) -> tuple[str, bytes]:
    now = datetime.utcnow()
    await db.execute(delete(PasskeyChallenge).where(PasskeyChallenge.expires_at <= now))
    raw_challenge = secrets.token_bytes(32)
    challenge_id = secrets.token_urlsafe(32)
    db.add(PasskeyChallenge(
        challenge_id=challenge_id,
        ceremony=ceremony,
        challenge=bytes_to_base64url(raw_challenge),
        expires_at=now + timedelta(seconds=settings.webauthn_challenge_ttl),
    ))
    await db.commit()
    return challenge_id, raw_challenge


async def consume_challenge(db: AsyncSession, challenge_id: str, ceremony: str) -> bytes:
    row = await db.get(PasskeyChallenge, challenge_id)
    now = datetime.utcnow()
    if row is None or row.ceremony != ceremony or row.consumed_at is not None or row.expires_at <= now:
        raise PasskeyError("通行密钥验证已过期或已使用，请重新发起验证")
    # Commit consumption before verifying the assertion so competing requests and
    # malformed assertions can never replay this challenge.
    row.consumed_at = now
    await db.commit()
    return base64url_to_bytes(row.challenge)


def registration_options(*, settings: Settings, owner: PasskeyOwner, challenge: bytes, credentials: list[PasskeyCredential]) -> dict[str, Any]:
    options = generate_registration_options(
        rp_id=settings.webauthn_rp_id,
        rp_name=settings.webauthn_rp_name,
        user_id=base64url_to_bytes(owner.user_handle),
        user_name=settings.admin_username,
        user_display_name=settings.admin_username,
        challenge=challenge,
        attestation=AttestationConveyancePreference.NONE,
        authenticator_selection=AuthenticatorSelectionCriteria(
            resident_key=ResidentKeyRequirement.REQUIRED,
            user_verification=UserVerificationRequirement.REQUIRED,
        ),
        exclude_credentials=[PublicKeyCredentialDescriptor(id=base64url_to_bytes(item.credential_id)) for item in credentials],
    )
    return json.loads(options_to_json(options))


def authentication_options(*, settings: Settings, challenge: bytes) -> dict[str, Any]:
    # Discoverable credentials avoid exposing an allowCredentials list and let
    # the authenticator return the matching user handle after biometric/PIN UV.
    options = generate_authentication_options(
        rp_id=settings.webauthn_rp_id,
        challenge=challenge,
        user_verification=UserVerificationRequirement.REQUIRED,
    )
    return json.loads(options_to_json(options))


def verify_registration(*, credential: dict[str, Any], expected_challenge: bytes, settings: Settings):
    try:
        return verify_registration_response(
            credential=credential,
            expected_challenge=expected_challenge,
            expected_rp_id=settings.webauthn_rp_id,
            expected_origin=settings.webauthn_origin_list,
            require_user_verification=True,
        )
    except Exception as exc:  # library-specific validation errors are intentionally uniform to callers
        raise PasskeyError("通行密钥验证失败，请重试") from exc


def verify_authentication(*, credential: dict[str, Any], expected_challenge: bytes, settings: Settings, stored: PasskeyCredential):
    try:
        return verify_authentication_response(
            credential=credential,
            expected_challenge=expected_challenge,
            expected_rp_id=settings.webauthn_rp_id,
            expected_origin=settings.webauthn_origin_list,
            credential_public_key=base64url_to_bytes(stored.public_key),
            credential_current_sign_count=stored.sign_count,
            require_user_verification=True,
        )
    except Exception as exc:
        raise PasskeyError("通行密钥验证失败，请重试") from exc
