import asyncio
import base64
import io
import os
from datetime import date, datetime, timedelta
from pathlib import Path

from fastapi.testclient import TestClient
from argon2 import PasswordHasher, Type
from PIL import Image

# API 回归测试绝不读取开发者的 .env、账号或真实缓存。
TEST_DB = Path(__file__).resolve().parents[1] / "data" / "test_api.db"
TEST_ADMIN_USERNAME = "test-admin"
TEST_ADMIN_PASSWORD = "change-me"
# Deterministic, test-only material. This is generated in-process rather than
# resembling a deployable credential; production configuration is never read.
TEST_SESSION_SECRET = "test-session-secret-only-for-unit-tests-1234567890"
TEST_FERNET_KEY = base64.urlsafe_b64encode(bytes(range(32))).decode("ascii")
if TEST_DB.exists():
    TEST_DB.unlink()
os.environ["ADMIN_USERNAME"] = TEST_ADMIN_USERNAME
os.environ["ADMIN_PASSWORD_HASH"] = PasswordHasher(type=Type.ID).hash(TEST_ADMIN_PASSWORD)
os.environ["SESSION_SECRET"] = TEST_SESSION_SECRET
os.environ["SESSION_MAX_AGE"] = "3600"
os.environ["SESSION_COOKIE_SECURE"] = "false"
os.environ["DATABASE_URL"] = "sqlite+aiosqlite:///./data/test_api.db"
os.environ["AUTO_CREATE_SCHEMA"] = "true"
# 仅用于测试数据库的派生 Fernet 密钥；与任何开发或生产密钥无关。
os.environ["AI_CREDENTIAL_MASTER_KEY"] = TEST_FERNET_KEY

from app.main import app, cleanup_expired_custom_schedules
from app import ai_analysis
from app import ai_jobs
from app.ai_worker import run_once
from app.db import SessionLocal
from app.db_models import Grade, GradeAiJob


GRADE_HTML = """<html><body><table>
<tr><th>课程编号</th><th>课程名称</th><th>课程性质</th><th>成绩</th><th>学分</th><th>绩点</th></tr>
<tr><td>C001</td><td>离线成绩分析测试</td><td>必修</td><td>88</td><td>3</td><td>3.8</td></tr>
</table></body></html>""".encode("utf-8")


def avatar_data_url(width: int, height: int) -> str:
    image_bytes = io.BytesIO()
    Image.new("RGB", (width, height), "#2563eb").save(image_bytes, format="PNG")
    return f"data:image/png;base64,{base64.b64encode(image_bytes.getvalue()).decode('ascii')}"


def login_headers(client: TestClient) -> dict[str, str]:
    login = client.post("/api/v1/auth/login", json={"username": TEST_ADMIN_USERNAME, "password": TEST_ADMIN_PASSWORD})
    assert login.status_code == 200
    assert "httponly" in login.headers["set-cookie"].lower()
    assert "samesite=lax" in login.headers["set-cookie"].lower()
    return {}


def import_test_grades(client: TestClient, headers: dict[str, str]) -> tuple[int, dict]:
    preview = client.post(
        "/api/v1/grades/import-file?term_id=2026-2027-1",
        headers=headers,
        files={"file": ("grades.html", GRADE_HTML, "text/html")},
    )
    assert preview.status_code == 200
    payload = preview.json()["data"]
    assert payload["source_term_id"] == "2026-2027-1"
    assert len(payload["grades"]) == 1
    confirm = client.post("/api/v1/grades/import-confirm", headers=headers, json=payload)
    assert confirm.status_code == 200
    return confirm.json()["data"]["term_id"], payload


def test_api_auth_and_local_file_import():
    with TestClient(app) as client:
        assert client.get("/api/v1/grades").status_code == 401
        assert client.post("/api/v1/auth/login", json={"username": TEST_ADMIN_USERNAME, "password": "wrong"}).status_code == 401
        assert client.post("/api/v1/auth/login", json={"username": "非ASCII用户", "password": "wrong"}).status_code == 401
        headers = login_headers(client)
        assert client.get("/api/v1/auth/me").json()["data"] == {"authenticated": True, "username": TEST_ADMIN_USERNAME}
        assert client.get("/api/v1/profile", headers=headers).json()["data"]["display_name"] == "用户"
        profile = client.put("/api/v1/profile", headers=headers, json={"display_name": "测试同学", "avatar_data_url": avatar_data_url(512, 512)})
        assert profile.json()["data"]["display_name"] == "测试同学"
        background = client.put("/api/v1/profile", headers=headers, json={"display_name": "测试同学", "timetable_background_data_url": avatar_data_url(720, 1280)})
        assert background.json()["data"]["timetable_background_data_url"] == avatar_data_url(720, 1280)
        home_wallpaper = client.put("/api/v1/profile", headers=headers, json={"display_name": "测试同学", "home_wallpaper_data_url": avatar_data_url(720, 1280)})
        assert home_wallpaper.json()["data"]["home_wallpaper_data_url"] == avatar_data_url(720, 1280)
        assert home_wallpaper.json()["data"]["timetable_background_data_url"] == avatar_data_url(720, 1280)
        removed_home_wallpaper = client.put("/api/v1/profile", headers=headers, json={"display_name": "测试同学", "home_wallpaper_data_url": None})
        assert removed_home_wallpaper.json()["data"]["home_wallpaper_data_url"] is None
        assert removed_home_wallpaper.json()["data"]["timetable_background_data_url"] == avatar_data_url(720, 1280)
        invalid_home_wallpaper = client.put("/api/v1/profile", headers=headers, json={"display_name": "测试同学", "home_wallpaper_data_url": avatar_data_url(640, 480)})
        assert invalid_home_wallpaper.status_code == 422
        analysis_wallpaper = client.put("/api/v1/profile", headers=headers, json={"display_name": "测试同学", "analysis_wallpaper_data_url": avatar_data_url(720, 1280)})
        assert analysis_wallpaper.status_code == 200
        assert analysis_wallpaper.json()["data"]["analysis_wallpaper_data_url"] == avatar_data_url(720, 1280)
        assert analysis_wallpaper.json()["data"]["settings_wallpaper_data_url"] is None
        settings_wallpaper = client.put("/api/v1/profile", headers=headers, json={"display_name": "测试同学", "settings_wallpaper_data_url": avatar_data_url(720, 1280)})
        assert settings_wallpaper.status_code == 200
        assert settings_wallpaper.json()["data"]["analysis_wallpaper_data_url"] == avatar_data_url(720, 1280)
        removed_analysis_wallpaper = client.put("/api/v1/profile", headers=headers, json={"display_name": "测试同学", "analysis_wallpaper_data_url": None})
        assert removed_analysis_wallpaper.json()["data"]["analysis_wallpaper_data_url"] is None
        assert removed_analysis_wallpaper.json()["data"]["settings_wallpaper_data_url"] == avatar_data_url(720, 1280)
        invalid_settings_wallpaper = client.put("/api/v1/profile", headers=headers, json={"display_name": "测试同学", "settings_wallpaper_data_url": avatar_data_url(640, 480)})
        assert invalid_settings_wallpaper.status_code == 422
        invalid_background = client.put("/api/v1/profile", headers=headers, json={"display_name": "测试同学", "timetable_background_data_url": avatar_data_url(640, 480)})
        assert invalid_background.status_code == 422
        non_square_avatar = client.put("/api/v1/profile", headers=headers, json={"display_name": "测试同学", "avatar_data_url": avatar_data_url(640, 480)})
        assert non_square_avatar.status_code == 422
        term_id, preview = import_test_grades(client, headers)
        grades = client.get(f"/api/v1/grades?term_id={term_id}", headers=headers).json()["data"]
        assert grades[0]["course_name"] == preview["grades"][0]["course_name"]
        summary = client.get(f"/api/v1/grades/summary?term_id={term_id}", headers=headers).json()["data"]
        assert summary["total_courses"] == 1 and summary["average_score"] == 88
        bad = client.post("/api/v1/grades/import-file?term_id=2026-2027-1", headers=headers, files={"file": ("not-a-grade.txt", b"x", "text/plain")})
        assert bad.status_code == 422
        terms = client.get("/api/v1/terms", headers=headers).json()["data"]
        assert any(term["id"] == term_id for term in terms)
        periods = client.get("/api/v1/settings/period-times", headers=headers).json()["data"]
        assert len(periods) == 13
        assert client.put(f"/api/v1/terms/{term_id}/start-date", headers=headers, json={"start_date": "2026-09-07"}).json()["success"]
        assert client.put("/api/v1/settings/period-times/1", headers=headers, json={"start_time": "08:35", "end_time": "09:20"}).json()["success"]
        assert client.put(f"/api/v1/terms/{term_id}/start-date", headers=headers, json={"start_date": "2026-09-08"}).status_code == 422


def test_delete_grades_is_scoped_to_one_term():
    with TestClient(app) as client:
        headers = login_headers(client)
        first_term_id, preview = import_test_grades(client, headers)
        other_preview = {
            **preview,
            "source_term_id": "2025-2026-2",
            "grades": [{**preview["grades"][0], "source_grade_id": "other-term-grade"}],
        }
        other_import = client.post("/api/v1/grades/import-confirm", headers=headers, json=other_preview)
        assert other_import.status_code == 200
        other_term_id = other_import.json()["data"]["term_id"]

        deleted = client.delete(f"/api/v1/grades?term_id={first_term_id}", headers=headers)
        assert deleted.status_code == 200
        assert deleted.json()["data"] == {"term_id": first_term_id, "grades_deleted": 1, "analyses_deleted": 0}
        assert client.get(f"/api/v1/grades?term_id={first_term_id}", headers=headers).json()["data"] == []
        assert len(client.get(f"/api/v1/grades?term_id={other_term_id}", headers=headers).json()["data"]) == 1
        assert client.delete("/api/v1/grades", headers=headers).status_code == 422


def test_custom_schedule_crud():
    with TestClient(app) as client:
        assert client.get("/api/v1/custom-schedules").status_code == 401
        headers = login_headers(client)
        scheduled_date = date.today().isoformat()
        created = client.post("/api/v1/custom-schedules", headers=headers, json={"title": "完成测试", "scheduled_date": scheduled_date, "scheduled_time": "09:30"})
        assert created.status_code == 200
        schedule_id = created.json()["data"]["id"]
        listed = client.get(f"/api/v1/custom-schedules?scheduled_date={scheduled_date}", headers=headers)
        assert "完成测试" in [item["title"] for item in listed.json()["data"]]
        updated = client.patch(f"/api/v1/custom-schedules/{schedule_id}", headers=headers, json={"title": "更新后的测试", "scheduled_date": scheduled_date, "scheduled_time": "08:00"})
        assert updated.json()["data"]["title"] == "更新后的测试"
        assert client.delete(f"/api/v1/custom-schedules/{schedule_id}", headers=headers).json()["data"]["deleted"]
        assert client.post("/api/v1/custom-schedules", headers=headers, json={"title": "x", "scheduled_date": scheduled_date, "scheduled_time": "9:00"}).status_code == 422
        yesterday = (date.today() - timedelta(days=1)).isoformat()
        assert client.post("/api/v1/custom-schedules", headers=headers, json={"title": "过期安排", "scheduled_date": yesterday, "scheduled_time": "09:00"}).status_code == 422


def test_expired_custom_schedules_are_cleaned_after_seven_days():
    with TestClient(app) as client:
        headers = login_headers(client)
        reference_date = date.today() + timedelta(days=8)
        assert client.post("/api/v1/custom-schedules", headers=headers, json={"title": "应清理", "scheduled_date": date.today().isoformat(), "scheduled_time": "09:00"}).status_code == 200
        assert client.post("/api/v1/custom-schedules", headers=headers, json={"title": "保留七天", "scheduled_date": (reference_date - timedelta(days=7)).isoformat(), "scheduled_time": "09:00"}).status_code == 200
        assert client.post("/api/v1/custom-schedules", headers=headers, json={"title": "未来安排", "scheduled_date": (reference_date + timedelta(days=5)).isoformat(), "scheduled_time": "09:00"}).status_code == 200
        assert asyncio.run(cleanup_expired_custom_schedules(reference_date)) >= 1
        titles = [item["title"] for item in client.get("/api/v1/custom-schedules", headers=headers).json()["data"]]
        assert "应清理" not in titles and "保留七天" in titles and "未来安排" in titles


def test_manual_course_crud_and_timetable_merge():
    with TestClient(app) as client:
        headers = login_headers(client)
        term_id, _ = import_test_grades(client, headers)
        assert client.put(f"/api/v1/terms/{term_id}/start-date", headers=headers, json={"start_date": "2026-09-07"}).status_code == 200
        payload = {"term_id": term_id, "course_name": "手动课程测试", "teacher": "测试教师", "classroom": "测试教室", "weekday": 1, "start_period": 1, "end_period": 2, "week_expression": "1-2周"}
        created = client.post("/api/v1/manual-courses", headers=headers, json=payload)
        assert created.status_code == 200
        manual_id = created.json()["data"]["id"]
        sessions = client.get(f"/api/v1/timetable?term_id={term_id}", headers=headers).json()["data"]
        manual_sessions = [item for item in sessions if item.get("manual_course_id") == manual_id]
        assert len(manual_sessions) == 2 and {item["source"] for item in manual_sessions} == {"MANUAL"}
        payload["course_name"] = "手动课程已更新"
        assert client.patch(f"/api/v1/manual-courses/{manual_id}", headers=headers, json=payload).json()["data"]["course_name"] == "手动课程已更新"
        assert client.delete(f"/api/v1/manual-courses/{manual_id}", headers=headers).json()["data"]["deleted"]
        assert client.post("/api/v1/manual-courses", headers=headers, json={**payload, "week_expression": "1-21周"}).status_code == 422


def test_single_owner_session_lifecycle_and_csrf():
    with TestClient(app) as client:
        login_headers(client)
        assert client.get("/api/v1/grades").status_code == 200
        # A forged cookie cannot be resolved to a server-side session.
        client.cookies.set("hand_helper_session", "forged-session-id")
        assert client.get("/api/v1/grades").status_code == 401
        client.cookies.clear()
        login_headers(client)
        assert client.post("/api/v1/custom-schedules", headers={"Origin": "https://attacker.invalid"}, json={"title": "不应创建", "scheduled_date": date.today().isoformat(), "scheduled_time": "09:00"}).status_code == 403
        assert client.post("/api/v1/auth/logout").status_code == 200
        assert client.get("/api/v1/grades").status_code == 401


def test_passkey_ceremonies_require_reauthentication_and_consume_challenges():
    with TestClient(app) as client:
        # Authentication options are public, but assertions use a short-lived,
        # one-time server challenge and no credential identifier is exposed.
        authentication = client.post("/api/v1/auth/passkey/options")
        assert authentication.status_code == 200
        authentication_data = authentication.json()["data"]
        assert authentication_data["challenge_id"] and authentication_data["public_key"]["rpId"] == "localhost"
        invalid_assertion = {"challenge_id": authentication_data["challenge_id"], "credential": {}}
        assert client.post("/api/v1/auth/passkey/verify", json=invalid_assertion).status_code == 401
        # A failed verification has still consumed the challenge, preventing replay.
        assert client.post("/api/v1/auth/passkey/verify", json=invalid_assertion).status_code == 401

        login_headers(client)
        assert client.post("/api/v1/auth/passkey/registration/options", json={"password": "wrong", "label": "测试设备"}).status_code == 401
        registration = client.post("/api/v1/auth/passkey/registration/options", json={"password": TEST_ADMIN_PASSWORD, "label": "测试设备"})
        assert registration.status_code == 200
        registration_data = registration.json()["data"]
        assert registration_data["label"] == "测试设备"
        assert registration_data["public_key"]["rp"]["id"] == "localhost"
        invalid_registration = {"challenge_id": registration_data["challenge_id"], "credential": {}}
        assert client.post("/api/v1/auth/passkey/registration/verify", json=invalid_registration).status_code == 422
        assert client.post("/api/v1/auth/passkey/registration/verify", json=invalid_registration).status_code == 422
        assert client.get("/api/v1/auth/passkeys").json()["data"] == []


def test_login_rate_limit_uses_ip_and_username():
    with TestClient(app) as client:
        for _ in range(5):
            assert client.post("/api/v1/auth/login", json={"username": "rate-test", "password": "wrong"}).status_code == 401
        assert client.post("/api/v1/auth/login", json={"username": "rate-test", "password": "wrong"}).status_code == 429


def test_session_survives_application_restart():
    with TestClient(app) as first_client:
        login_headers(first_client)
        session_id = first_client.cookies.get("hand_helper_session")
        assert session_id
    with TestClient(app) as restarted_client:
        restarted_client.cookies.set("hand_helper_session", session_id)
        assert restarted_client.get("/api/v1/auth/me").status_code == 200


def test_ai_grade_analysis_is_encrypted_and_cached(monkeypatch):
    async def fake_model_call(_endpoint, _api_key, _model, _messages, **_kwargs):
        return "整体概览：表现稳定。\n\n优势课程：基础扎实。\n\n需要关注：继续复盘。\n\n可执行建议：制定下周计划。"

    async def fake_model_list(_endpoint, _api_key):
        return ["model-a", "model-b"]

    monkeypatch.setattr(ai_analysis, "_post_openai_compatible", fake_model_call)
    monkeypatch.setattr(ai_analysis, "_get_openai_compatible_models", fake_model_list)
    with TestClient(app) as client:
        headers = login_headers(client)
        term_id, _ = import_test_grades(client, headers)
        initial = client.get("/api/v1/ai/settings", headers=headers)
        assert initial.status_code == 200 and not initial.json()["data"]["configured"]
        models = client.post(
            "/api/v1/ai/settings/models",
            headers=headers,
            json={"provider": "APIKEY.FUN", "base_url": "https://api.apikey.fun/v1", "api_key": "test-api-key-1234"},
        )
        assert models.status_code == 200
        assert models.json()["data"]["models"] == ["model-a", "model-b"]
        tested = client.post(
            "/api/v1/ai/settings/test",
            headers=headers,
            json={"provider": "APIKEY.FUN", "base_url": "https://api.apikey.fun/v1", "model": "test-model", "api_key": "test-api-key-1234"},
        )
        assert tested.status_code == 200
        assert tested.json()["data"]["message"] == "模型服务连接成功，尚未保存配置"
        assert client.get("/api/v1/ai/settings", headers=headers).json()["data"]["configured"] is False
        legacy_saved = client.put(
            "/api/v1/ai/settings",
            headers=headers,
            json={"provider": "APIKEY.FUN", "base_url": "https://api.apikey.fun/v1", "model": "model-b", "api_key": "test-api-key-1234"},
        )
        assert legacy_saved.status_code == 200
        assert legacy_saved.json()["data"]["requires_apikey_fan_migration"] is True
        migrated = client.post("/api/v1/ai/settings/migrate-apikey-fan", headers=headers)
        assert migrated.status_code == 200
        assert migrated.json()["data"]["provider"] == "APIKEY.FAN"
        assert migrated.json()["data"]["base_url"] == "https://api.apikey.fan/v1"
        assert migrated.json()["data"]["model"] == "model-b"
        assert migrated.json()["data"]["requires_apikey_fan_migration"] is False
        saved = client.put(
            "/api/v1/ai/settings",
            headers=headers,
            json={"provider": "测试服务", "base_url": "https://api.example.com/v1", "model": "model-a", "api_key": "test-api-key-1234"},
        )
        assert saved.status_code == 200
        assert saved.json()["data"]["api_key_hint"] == "****1234"
        assert saved.json()["data"]["available_models"] == ["model-a", "model-b"]
        selected_model = client.patch("/api/v1/ai/settings/model", headers=headers, json={"model": "model-b"})
        assert selected_model.status_code == 200 and selected_model.json()["data"]["model"] == "model-b"
        refreshed_models = client.post("/api/v1/ai/settings/models/refresh", headers=headers)
        assert refreshed_models.status_code == 200
        assert refreshed_models.json()["data"]["available_models"] == ["model-a", "model-b"]
        first = client.post(f"/api/v1/grades/ai-analysis?term_id={term_id}", headers=headers)
        assert first.status_code == 200 and first.json()["data"]["cached"] is False
        cached = client.post(f"/api/v1/grades/ai-analysis?term_id={term_id}", headers=headers)
        assert cached.status_code == 200 and cached.json()["data"]["cached"] is True
        session_id = client.cookies.get("hand_helper_session")
        client.cookies.clear()
        unauthenticated_history = client.get(f"/api/v1/grades/ai-analyses?term_id={term_id}")
        assert unauthenticated_history.status_code == 401
        client.cookies.set("hand_helper_session", session_id)
        history = client.get(f"/api/v1/grades/ai-analyses?term_id={term_id}", headers=headers)
        assert history.status_code == 200
        assert len(history.json()["data"]) == 1
        assert history.json()["data"][0]["model"] == "model-b"
        cleared_history = client.delete(f"/api/v1/grades/ai-analyses?term_id={term_id}", headers=headers)
        assert cleared_history.status_code == 200 and cleared_history.json()["data"]["deleted"] == 1
        assert client.get(f"/api/v1/grades/ai-analyses?term_id={term_id}", headers=headers).json()["data"] == []
        assert client.delete("/api/v1/ai/settings", headers=headers).json()["data"]["deleted"]


def test_durable_ai_jobs_are_deduplicated_cancelable_and_persist_results(monkeypatch):
    model_calls: list[tuple[str, str]] = []

    async def fake_model_call(_endpoint, _api_key, _model, _messages, **_kwargs):
        model_calls.append((_endpoint, _model))
        return "## 整体概览\n- 稳定\n## 优势课程\n- 基础\n## 需要关注\n- 复盘\n## 可执行建议\n- 计划"

    async def fake_model_list(_endpoint, _api_key):
        return ["job-model"]

    monkeypatch.setattr(ai_analysis, "_get_openai_compatible_models", fake_model_list)
    monkeypatch.setattr(ai_jobs, "_post_openai_compatible", fake_model_call)
    with TestClient(app) as client:
        headers = login_headers(client)
        term_id, _ = import_test_grades(client, headers)
        configured = client.put(
            "/api/v1/ai/settings",
            headers=headers,
            json={"provider": "APIKEY.FAN", "base_url": "https://api.apikey.fan/v1", "model": "job-model", "api_key": "test-api-key-1234"},
        )
        assert configured.status_code == 200

        first = client.post(f"/api/v1/grades/ai-analysis/jobs?term_id={term_id}", headers=headers)
        assert first.status_code == 202
        first_data = first.json()["data"]
        assert first_data["status"] == "queued" and not first_data["reused"]

        duplicate = client.post(f"/api/v1/grades/ai-analysis/jobs?term_id={term_id}", headers=headers)
        assert duplicate.status_code == 202
        assert duplicate.json()["data"]["job_id"] == first_data["job_id"]
        assert duplicate.json()["data"]["reused"] is True

        # The task survives a client that no longer polls its status.
        assert asyncio.run(run_once("test-ai-worker")) is True
        completed = client.get(f"/api/v1/grades/ai-analysis/jobs/{first_data['job_id']}", headers=headers)
        completed_data = completed.json()["data"]
        assert completed_data["status"] == "succeeded"
        assert completed_data["analysis"]["content"].startswith("## 整体概览")
        # execute_job() releases its read transaction before calling the
        # provider.  The setting must already be detached into scalar values,
        # otherwise rollback expires it and a MissingGreenlet failure is stored
        # instead of this successful result.
        assert model_calls == [("https://api.apikey.fan/v1/chat/completions", "job-model")]

        cached = client.post(f"/api/v1/grades/ai-analysis/jobs?term_id={term_id}", headers=headers)
        assert cached.json()["data"]["status"] == "succeeded"
        assert cached.json()["data"]["cached"] is True
        assert len(model_calls) == 1

        # Reusing a client key for a different provider configuration must not
        # silently return the original completed job.
        keyed = client.post(
            f"/api/v1/grades/ai-analysis/jobs?term_id={term_id}&force_refresh=true",
            headers={**headers, "Idempotency-Key": "configuration-conflict"},
        )
        assert keyed.status_code == 202
        changed = client.put(
            "/api/v1/ai/settings",
            headers=headers,
            json={"provider": "APIKEY.FAN", "base_url": "https://api2.apikey.fan/v1", "model": "job-model", "api_key": "test-api-key-1234"},
        )
        assert changed.status_code == 200
        conflict = client.post(
            f"/api/v1/grades/ai-analysis/jobs?term_id={term_id}&force_refresh=true",
            headers={**headers, "Idempotency-Key": "configuration-conflict"},
        )
        assert conflict.status_code == 409
        assert client.put(
            "/api/v1/ai/settings",
            headers=headers,
            json={"provider": "APIKEY.FAN", "base_url": "https://api.apikey.fan/v1", "model": "job-model", "api_key": "test-api-key-1234"},
        ).status_code == 200

        async def submit_from_independent_session() -> str:
            async with SessionLocal() as db:
                result = await ai_jobs.create_or_reuse_job(
                    db,
                    owner=TEST_ADMIN_USERNAME,
                    term_id=term_id,
                    force_refresh=True,
                    idempotency_key=None,
                )
                return result.job_id

        # Separate request sessions converge on the one active snapshot job.
        # The partial unique index remains the race-safe guard for true overlap.
        first_force = asyncio.run(submit_from_independent_session())
        second_force = asyncio.run(submit_from_independent_session())
        assert first_force == second_force
        force_job = first_force
        assert client.post(f"/api/v1/grades/ai-analysis/jobs/{force_job}/cancel", headers=headers).json()["data"]["status"] == "cancelled"

        async def fake_rate_limited(*_args, **_kwargs):
            raise ai_analysis.AiServiceError("模型服务请求过于频繁或额度不足，请稍后再试", code="UPSTREAM_RATE_LIMITED")

        monkeypatch.setattr(ai_jobs, "_post_openai_compatible", fake_rate_limited)
        failed = client.post(
            f"/api/v1/grades/ai-analysis/jobs?term_id={term_id}&force_refresh=true",
            headers={**headers, "Idempotency-Key": "rate-limit-test"},
        )
        failed_job = failed.json()["data"]["job_id"]
        assert asyncio.run(run_once("test-ai-worker")) is True
        failed_status = client.get(f"/api/v1/grades/ai-analysis/jobs/{failed_job}", headers=headers).json()["data"]
        assert failed_status["status"] == "failed"
        assert failed_status["error_code"] == "UPSTREAM_RATE_LIMITED"


def test_ai_job_snapshot_change_and_late_worker_cannot_overwrite_cancelled_result(monkeypatch):
    async def fake_model_list(_endpoint, _api_key):
        return ["job-model"]

    async def fake_model_call(*_args, **_kwargs):
        return "## 整体概览\n- 不应在已取消任务中保存"

    monkeypatch.setattr(ai_analysis, "_get_openai_compatible_models", fake_model_list)
    monkeypatch.setattr(ai_jobs, "_post_openai_compatible", fake_model_call)
    with TestClient(app) as client:
        headers = login_headers(client)
        term_id, _ = import_test_grades(client, headers)
        assert client.put(
            "/api/v1/ai/settings",
            headers=headers,
            json={"provider": "APIKEY.FAN", "base_url": "https://api.apikey.fan/v1", "model": "job-model", "api_key": "test-api-key-1234"},
        ).status_code == 200

        stale = client.post(f"/api/v1/grades/ai-analysis/jobs?term_id={term_id}&force_refresh=true", headers=headers)
        stale_id = stale.json()["data"]["job_id"]

        async def change_snapshot() -> None:
            async with SessionLocal() as db:
                grade = await db.scalar(select(Grade).where(Grade.term_id == term_id))
                assert grade is not None
                grade.score = "89"
                await db.commit()

        from sqlalchemy import select
        asyncio.run(change_snapshot())
        assert asyncio.run(run_once("snapshot-change-worker")) is True
        stale_status = client.get(f"/api/v1/grades/ai-analysis/jobs/{stale_id}", headers=headers).json()["data"]
        assert stale_status["status"] == "failed"
        assert stale_status["error_code"] == "SNAPSHOT_CHANGED"

        late = client.post(f"/api/v1/grades/ai-analysis/jobs?term_id={term_id}&force_refresh=true", headers=headers)
        late_id = late.json()["data"]["job_id"]

        async def claim_then_cancel() -> None:
            async with SessionLocal() as db:
                assert await ai_jobs.claim_next_job(db, worker_id="late-worker") == late_id
            async with SessionLocal() as db:
                await ai_jobs.cancel_job(db, owner=TEST_ADMIN_USERNAME, job_id=late_id)
            async with SessionLocal() as db:
                await ai_jobs.execute_job(db, worker_id="late-worker", job_id=late_id)

        asyncio.run(claim_then_cancel())
        late_status = client.get(f"/api/v1/grades/ai-analysis/jobs/{late_id}", headers=headers).json()["data"]
        assert late_status["status"] == "cancelled"
        assert late_status["analysis_id"] is None


def test_ai_worker_marks_expired_running_lease_unknown():
    with TestClient(app) as client:
        headers = login_headers(client)
        term_id, _ = import_test_grades(client, headers)

    async def create_expired() -> str:
        async with SessionLocal() as db:
            row = GradeAiJob(
                job_id="expired-worker-lease-job",
                owner=TEST_ADMIN_USERNAME,
                term_id=term_id,
                input_hash="f" * 64,
                provider="APIKEY.FAN",
                model="job-model",
                configuration_hash="c" * 64,
                idempotency_key="expired-lease",
                status="running",
                attempt=1,
                lease_owner="dead-worker",
                lease_expires_at=datetime.utcnow() - timedelta(days=1),
            )
            db.add(row)
            await db.commit()
            return row.job_id

    async def assert_recovered() -> None:
        async with SessionLocal() as db:
            recovered = await ai_jobs.recover_expired_leases(db)
            assert recovered >= 1
            # Other tests may have already inserted jobs; look up by stable ID.
            from sqlalchemy import select
            row = await db.scalar(select(GradeAiJob).where(GradeAiJob.job_id == "expired-worker-lease-job"))
            assert row is not None and row.status == "unknown"
            assert row.error_code == "WORKER_LEASE_EXPIRED"

    asyncio.run(create_expired())
    asyncio.run(assert_recovered())
