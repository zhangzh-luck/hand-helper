package com.zhangzh.hangassistant

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.toHttpUrl
import org.json.JSONObject
import org.json.JSONArray
import java.io.IOException
import java.util.concurrent.TimeUnit

data class AppProfile(val displayName: String)
data class AcademicTerm(
    val id: Int,
    val displayName: String,
    val startDate: String?,
    val isCurrent: Boolean,
)
data class TimetableSession(
    val id: Int,
    val courseName: String,
    val sessionDate: String,
    val startDateTime: String,
    val endDateTime: String,
    val classroom: String?,
    val teacher: String?,
    val weekExpression: String?,
    val termId: Int?,
)
data class GradeItem(
    val id: Int,
    val termId: Int,
    val courseName: String,
    val courseType: String?,
    val credits: Double?,
    val score: String?,
    val gradePoint: Double?,
    val examType: String?,
)
data class GradeSummary(
    val totalCourses: Int,
    val earnedCredits: Double,
    val averageScore: Double?,
    val gpa: Double?,
    val failedCourses: Int,
)

class HandHelperApi(sessionStore: SecureSessionStore) {
    private val cookieJar = SessionCookieJar(sessionStore)
    private val client = OkHttpClient.Builder()
        .cookieJar(cookieJar)
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .callTimeout(25, TimeUnit.SECONDS)
        .build()

    suspend fun login(username: String, password: String): Result<NativeSession> = requestResult {
        cookieJar.clear()
        val payload = JSONObject().put("username", username).put("password", password)
        val request = Request.Builder()
            .url("${BuildConfig.HAND_HELPER_API_BASE_URL}/api/v1/auth/login")
            .header("Origin", BuildConfig.HAND_HELPER_API_BASE_URL)
            .post(payload.toString().toRequestBody(JSON_MEDIA_TYPE))
            .build()
        val data = successfulData(execute(request))
        NativeSession(data.optString("username").ifBlank { username })
    }

    suspend fun logout(): Result<Unit> = requestResult {
        val request = Request.Builder()
            .url("${BuildConfig.HAND_HELPER_API_BASE_URL}/api/v1/auth/logout")
            .header("Origin", BuildConfig.HAND_HELPER_API_BASE_URL)
            .post("".toRequestBody(JSON_MEDIA_TYPE))
            .build()
        execute(request)
        cookieJar.clear()
    }

    suspend fun profile(): Result<AppProfile> = requestResult {
        val request = Request.Builder()
            .url("${BuildConfig.HAND_HELPER_API_BASE_URL}/api/v1/profile")
            .get()
            .build()
        execute(request).let { root -> AppProfile(successfulData(root).optString("display_name", "同学")) }
    }

    suspend fun checkSession(): Result<Unit> = requestResult {
        val request = Request.Builder()
            .url("${BuildConfig.HAND_HELPER_API_BASE_URL}/api/v1/auth/me")
            .get()
            .build()
        successfulData(execute(request))
    }

    suspend fun terms(): Result<List<AcademicTerm>> = requestResult {
        val array = authenticatedData("/api/v1/terms") as JSONArray
        buildList {
            for (index in 0 until array.length()) {
                val item = array.getJSONObject(index)
                add(
                    AcademicTerm(
                        id = item.getInt("id"),
                        displayName = item.optString("display_name"),
                        startDate = item.optString("start_date").ifBlank { null },
                        isCurrent = item.optBoolean("is_current", false),
                    ),
                )
            }
        }
    }

    suspend fun timetableWeek(weekStart: String): Result<List<TimetableSession>> = requestResult {
        val array = authenticatedData("/api/v1/timetable/week?week_start=$weekStart") as JSONArray
        buildList {
            for (index in 0 until array.length()) {
                val item = array.getJSONObject(index)
                add(
                    TimetableSession(
                        id = item.getInt("id"),
                        courseName = item.optString("course_name", "未命名课程"),
                        sessionDate = item.optString("session_date"),
                        startDateTime = item.optString("start_datetime"),
                        endDateTime = item.optString("end_datetime"),
                        classroom = item.optString("classroom").ifBlank { null },
                        teacher = item.optString("teacher").ifBlank { null },
                        weekExpression = item.optString("week_expression").ifBlank { null },
                        termId = if (item.has("term_id") && !item.isNull("term_id")) item.getInt("term_id") else null,
                    ),
                )
            }
        }
    }

    suspend fun grades(termId: Int): Result<List<GradeItem>> = requestResult {
        val array = authenticatedData("/api/v1/grades?term_id=$termId") as JSONArray
        buildList {
            for (index in 0 until array.length()) {
                val item = array.getJSONObject(index)
                add(
                    GradeItem(
                        id = item.getInt("id"),
                        termId = item.getInt("term_id"),
                        courseName = item.optString("course_name", "未命名课程"),
                        courseType = item.optString("course_type").ifBlank { null },
                        credits = item.optionalDouble("credits"),
                        score = item.optString("score").ifBlank { null },
                        gradePoint = item.optionalDouble("grade_point"),
                        examType = item.optString("exam_type").ifBlank { null },
                    ),
                )
            }
        }
    }

    suspend fun gradeSummary(termId: Int): Result<GradeSummary> = requestResult {
        val item = authenticatedData("/api/v1/grades/summary?term_id=$termId") as JSONObject
        GradeSummary(
            totalCourses = item.optInt("total_courses"),
            earnedCredits = item.optDouble("earned_credits"),
            averageScore = item.optionalDouble("average_score"),
            gpa = item.optionalDouble("gpa"),
            failedCourses = item.optInt("failed_courses"),
        )
    }

    private fun execute(request: Request): JSONObject = client.newCall(request).execute().use { response ->
        val body = response.body?.string().orEmpty()
        val root = if (body.isBlank()) JSONObject() else JSONObject(body)
        if (!response.isSuccessful) {
            if (response.code == 401) cookieJar.clear()
            throw IOException(root.optJSONObject("error")?.optString("message") ?: "服务器请求失败（${response.code}）")
        }
        root
    }

    private fun successfulData(root: JSONObject): JSONObject {
        if (!root.optBoolean("success", false)) {
            throw IOException(root.optJSONObject("error")?.optString("message") ?: "请求未成功")
        }
        return root.optJSONObject("data") ?: throw IOException("服务器未返回有效数据")
    }

    private fun authenticatedData(path: String): Any {
        val request = Request.Builder()
            .url("${BuildConfig.HAND_HELPER_API_BASE_URL}$path")
            .get()
            .build()
        val root = execute(request)
        if (!root.optBoolean("success", false)) {
            throw IOException(root.optJSONObject("error")?.optString("message") ?: "请求未成功")
        }
        return root.opt("data") ?: throw IOException("服务器未返回有效数据")
    }

    private suspend fun <T> requestResult(block: () -> T): Result<T> = withContext(Dispatchers.IO) {
        runCatching(block)
    }

    private fun JSONObject.optionalDouble(name: String): Double? =
        if (has(name) && !isNull(name)) optDouble(name) else null

    private companion object {
        val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
    }
}

/** CookieJar is deliberately host-scoped so this session is never sent to another host. */
private class SessionCookieJar(private val sessionStore: SecureSessionStore) : CookieJar {
    private val apiUrl: HttpUrl = BuildConfig.HAND_HELPER_API_BASE_URL.toHttpUrl()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        if (url.host != apiUrl.host) return
        cookies.firstOrNull { it.name == SESSION_COOKIE_NAME }?.let { cookie ->
            sessionStore.saveSessionCookie(cookie.value)
        }
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        if (url.host != apiUrl.host) return emptyList()
        val value = sessionStore.sessionCookie() ?: return emptyList()
        return listOf(
            Cookie.Builder()
                .name(SESSION_COOKIE_NAME)
                .value(value)
                .hostOnlyDomain(apiUrl.host)
                .path("/")
                .secure()
                .httpOnly()
                .build(),
        )
    }

    fun clear() = sessionStore.clear()

    private companion object {
        const val SESSION_COOKIE_NAME = "hand_helper_session"
    }
}
