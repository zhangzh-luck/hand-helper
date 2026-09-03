package com.zhangzh.hangassistant

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
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

class HandHelperApi {
    private val client = OkHttpClient.Builder()
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .callTimeout(25, TimeUnit.SECONDS)
        .build()

    suspend fun login(username: String, password: String): Result<AuthTokens> = requestResult {
        val payload = JSONObject().put("username", username).put("password", password)
        val request = Request.Builder()
            .url("${BuildConfig.HAND_HELPER_API_BASE_URL}/api/v1/auth/login")
            .post(payload.toString().toRequestBody(JSON_MEDIA_TYPE))
            .build()
        execute(request).let { root ->
            val data = successfulData(root)
            AuthTokens(data.getString("access_token"), data.getString("refresh_token"))
        }
    }

    suspend fun profile(accessToken: String): Result<AppProfile> = requestResult {
        val request = Request.Builder()
            .url("${BuildConfig.HAND_HELPER_API_BASE_URL}/api/v1/profile")
            .header("Authorization", "Bearer $accessToken")
            .get()
            .build()
        execute(request).let { root -> AppProfile(successfulData(root).optString("display_name", "同学")) }
    }

    suspend fun checkSession(accessToken: String): Result<Unit> = profile(accessToken).map { Unit }

    suspend fun terms(accessToken: String): Result<List<AcademicTerm>> = requestResult {
        val array = authenticatedData("/api/v1/terms", accessToken) as JSONArray
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

    suspend fun timetableWeek(accessToken: String, weekStart: String): Result<List<TimetableSession>> = requestResult {
        val array = authenticatedData("/api/v1/timetable/week?week_start=$weekStart", accessToken) as JSONArray
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

    suspend fun grades(accessToken: String, termId: Int): Result<List<GradeItem>> = requestResult {
        val array = authenticatedData("/api/v1/grades?term_id=$termId", accessToken) as JSONArray
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

    suspend fun gradeSummary(accessToken: String, termId: Int): Result<GradeSummary> = requestResult {
        val item = authenticatedData("/api/v1/grades/summary?term_id=$termId", accessToken) as JSONObject
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
        if (!response.isSuccessful) throw IOException(root.optJSONObject("error")?.optString("message") ?: "服务器请求失败（${response.code}）")
        root
    }

    private fun successfulData(root: JSONObject): JSONObject {
        if (!root.optBoolean("success", false)) {
            throw IOException(root.optJSONObject("error")?.optString("message") ?: "请求未成功")
        }
        return root.optJSONObject("data") ?: throw IOException("服务器未返回有效数据")
    }

    private fun authenticatedData(path: String, accessToken: String): Any {
        val request = Request.Builder()
            .url("${BuildConfig.HAND_HELPER_API_BASE_URL}$path")
            .header("Authorization", "Bearer $accessToken")
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
