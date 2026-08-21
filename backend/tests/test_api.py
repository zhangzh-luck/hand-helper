import asyncio
import os
from datetime import date, timedelta
from pathlib import Path

from fastapi.testclient import TestClient

# API 回归测试绝不读取开发者的 .env、账号或真实缓存。
TEST_DB = Path(__file__).resolve().parents[1] / "data" / "test_api.db"
if TEST_DB.exists():
    TEST_DB.unlink()
os.environ["APP_ADMIN_USERNAME"] = "admin"
os.environ["APP_ADMIN_PASSWORD_HASH"] = "$2b$12$aK5M/nGGxmVBqk5w7cSTh.uhF3vDyphBKwywutAUyhjnDWuwJih6W"
os.environ["DATABASE_URL"] = "sqlite+aiosqlite:///./data/test_api.db"
os.environ["AUTO_CREATE_SCHEMA"] = "true"
# 仅用于测试数据库的固定 Fernet 密钥；与任何开发或生产密钥无关。
os.environ["AI_CREDENTIAL_MASTER_KEY"] = "0o-MuR1Cj_rJcOE5iO-1rSo6GF4vf95CIzv0c0cHkN4="

from app.main import app, cleanup_expired_custom_schedules
from app import ai_analysis


GRADE_HTML = """<html><body><table>
<tr><th>课程编号</th><th>课程名称</th><th>课程性质</th><th>成绩</th><th>学分</th><th>绩点</th></tr>
<tr><td>C001</td><td>离线成绩分析测试</td><td>必修</td><td>88</td><td>3</td><td>3.8</td></tr>
</table></body></html>""".encode("utf-8")


def login_headers(client: TestClient) -> dict[str, str]:
    login = client.post("/api/v1/auth/login", json={"username": "admin", "password": "change-me"})
    assert login.status_code == 200
    return {"Authorization": f"Bearer {login.json()['data']['access_token']}"}


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
        headers = login_headers(client)
        assert client.get("/api/v1/profile", headers=headers).json()["data"]["display_name"] == "用户"
        profile = client.put("/api/v1/profile", headers=headers, json={"display_name": "测试同学", "avatar_data_url": "data:image/png;base64,aGVsbG8="})
        assert profile.json()["data"]["display_name"] == "测试同学"
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


def test_app_account_can_change_username_and_password():
    with TestClient(app) as client:
        headers = login_headers(client)
        assert client.get("/api/v1/auth/account", headers=headers).json()["data"]["username"] == "admin"
        assert client.put("/api/v1/auth/account", headers=headers, json={"username": "new-admin", "current_password": "wrong-password"}).status_code == 401
        changed = client.put("/api/v1/auth/account", headers=headers, json={"username": "new-admin", "current_password": "change-me", "new_password": "new-password"})
        assert changed.status_code == 200
        assert client.post("/api/v1/auth/login", json={"username": "new-admin", "password": "new-password"}).status_code == 200
        restored = client.put("/api/v1/auth/account", headers=headers, json={"username": "admin", "current_password": "new-password", "new_password": "change-me"})
        assert restored.status_code == 200


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
        unauthenticated_history = client.get(f"/api/v1/grades/ai-analyses?term_id={term_id}")
        assert unauthenticated_history.status_code == 401
        history = client.get(f"/api/v1/grades/ai-analyses?term_id={term_id}", headers=headers)
        assert history.status_code == 200
        assert len(history.json()["data"]) == 1
        assert history.json()["data"][0]["model"] == "model-b"
        cleared_history = client.delete(f"/api/v1/grades/ai-analyses?term_id={term_id}", headers=headers)
        assert cleared_history.status_code == 200 and cleared_history.json()["data"]["deleted"] == 1
        assert client.get(f"/api/v1/grades/ai-analyses?term_id={term_id}", headers=headers).json()["data"] == []
        assert client.delete("/api/v1/ai/settings", headers=headers).json()["data"]["deleted"]
