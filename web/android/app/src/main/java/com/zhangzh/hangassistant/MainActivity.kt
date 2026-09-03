package com.zhangzh.hangassistant

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.School
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            HandHelperTheme {
                HandHelperApp(SecureTokenStore(applicationContext), HandHelperApi(), onExit = { finish() })
            }
        }
    }
}

@Composable
private fun HandHelperTheme(content: @Composable () -> Unit) {
    val colors = if (androidx.compose.foundation.isSystemInDarkTheme()) {
        darkColorScheme(primary = androidx.compose.ui.graphics.Color(0xFF9BBEFF), secondary = androidx.compose.ui.graphics.Color(0xFFB8C7E8))
    } else {
        lightColorScheme(primary = androidx.compose.ui.graphics.Color(0xFF2563EB), secondary = androidx.compose.ui.graphics.Color(0xFF465C80))
    }
    MaterialTheme(colorScheme = colors, content = content)
}

@Composable
private fun HandHelperApp(tokenStore: SecureTokenStore, api: HandHelperApi, onExit: () -> Unit) {
    if (BuildConfig.HAND_HELPER_USE_LOCAL_PREVIEW) {
        PreviewShell(onExit)
        return
    }
    var tokens by remember { mutableStateOf(tokenStore.read()) }
    if (tokens == null) {
        LoginScreen(api = api, onLoggedIn = { value -> tokenStore.save(value); tokens = value })
    } else {
        NativeShell(api = api, tokens = tokens!!, onLogout = { tokenStore.clear(); tokens = null }, onExit = onExit)
    }
}

/**
 * Deliberately local-only during the native UI migration.  The production API client stays in
 * HandHelperApi so each screen can be wired back after its visual behaviour is accepted.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PreviewShell(onExit: () -> Unit) {
    var destination by rememberSaveable { mutableStateOf(NativeDestination.TODAY) }
    var exitDialog by rememberSaveable { mutableStateOf(false) }
    BackHandler { exitDialog = true }
    if (exitDialog) AlertDialog(
        onDismissRequest = { exitDialog = false },
        title = { Text("退出航的助手？") },
        text = { Text("这是本地界面预览，确认后将关闭应用。") },
        dismissButton = { TextButton(onClick = { exitDialog = false }) { Text("取消") } },
        confirmButton = { TextButton(onClick = onExit) { Text("退出") } },
    )
    Scaffold(
        bottomBar = { WebInspiredDock(destination) { destination = it } },
    ) { padding ->
        when (destination) {
            NativeDestination.TODAY -> PreviewTodayScreen(padding)
            NativeDestination.TIMETABLE -> PreviewTimetableScreen(padding)
            NativeDestination.GRADES -> PreviewGradesScreen(padding)
            NativeDestination.SETTINGS -> PreviewSettingsScreen(padding)
        }
    }
}

@Composable
private fun WebInspiredDock(selected: NativeDestination, onSelected: (NativeDestination) -> Unit) {
    val entries = listOf(
        NativeDestination.TODAY to Icons.Outlined.Home,
        NativeDestination.TIMETABLE to Icons.Outlined.CalendarMonth,
        NativeDestination.GRADES to Icons.Outlined.School,
        NativeDestination.SETTINGS to Icons.Outlined.Settings,
    )
    Surface(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
        shape = RoundedCornerShape(23.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.9f),
        shadowElevation = 10.dp,
        tonalElevation = 3.dp,
    ) {
        Row(Modifier.fillMaxWidth().padding(5.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            entries.forEach { (destination, icon) ->
                val active = destination == selected
                Surface(
                    onClick = { onSelected(destination) },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(17.dp),
                    color = if (active) MaterialTheme.colorScheme.surface else Color.Transparent,
                    shadowElevation = if (active) 4.dp else 0.dp,
                ) {
                    Column(
                        modifier = Modifier.padding(vertical = 7.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Icon(icon, null, tint = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(21.dp))
                        Text(destination.title, style = MaterialTheme.typography.labelSmall, color = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
private fun LoginScreen(api: HandHelperApi, onLoggedIn: (AuthTokens) -> Unit) {
    var username by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var loading by rememberSaveable { mutableStateOf(false) }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    val login: () -> Unit = {
        if (username.isBlank() || password.isBlank()) {
            error = "请输入账号和密码"
        } else {
            loading = true
        }
    }
    LaunchedEffect(loading) {
        if (loading) {
            api.login(username.trim(), password).onSuccess(onLoggedIn).onFailure { error = it.message ?: "登录失败" }
            loading = false
        }
    }
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 28.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Text("航的助手", style = MaterialTheme.typography.displaySmall)
        Spacer(Modifier.height(10.dp))
        Text("Hand Helper", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(36.dp))
        OutlinedTextField(value = username, onValueChange = { username = it }, modifier = Modifier.fillMaxWidth(), label = { Text("账号") }, singleLine = true)
        Spacer(Modifier.height(14.dp))
        OutlinedTextField(
            value = password,
            onValueChange = { password = it },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("密码") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
        )
        if (error != null) Text(error!!, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp))
        Spacer(Modifier.height(22.dp))
        Button(onClick = login, enabled = !loading, modifier = Modifier.fillMaxWidth().height(52.dp)) {
            if (loading) CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp) else Text("登录")
        }
    }
}

private enum class NativeDestination(val title: String) { TODAY("今日"), TIMETABLE("课程表"), GRADES("成绩分析"), SETTINGS("设置") }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NativeShell(api: HandHelperApi, tokens: AuthTokens, onLogout: () -> Unit, onExit: () -> Unit) {
    var destination by rememberSaveable { mutableStateOf(NativeDestination.TODAY) }
    var exitDialog by rememberSaveable { mutableStateOf(false) }
    // Bottom-navigation destinations are siblings: a system Back action must not silently switch tabs.
    BackHandler { exitDialog = true }
    if (exitDialog) AlertDialog(
        onDismissRequest = { exitDialog = false },
        title = { Text("退出航的助手？") },
        text = { Text("再次确认后将关闭应用。") },
        dismissButton = { TextButton(onClick = { exitDialog = false }) { Text("取消") } },
        confirmButton = { TextButton(onClick = onExit) { Text("退出") } },
    )
    Scaffold(
        topBar = { CenterAlignedTopAppBar(title = { Text(destination.title) }) },
        bottomBar = { NativeNavigation(destination) { destination = it } },
    ) { padding ->
        when (destination) {
            NativeDestination.TODAY -> TodayScreen(api, tokens.accessToken, padding)
            NativeDestination.TIMETABLE -> TimetableScreen(api, tokens.accessToken, padding)
            NativeDestination.GRADES -> GradesScreen(api, tokens.accessToken, padding)
            NativeDestination.SETTINGS -> SettingsScreen(api, tokens.accessToken, padding, onLogout)
        }
    }
}

@Composable
private fun NativeNavigation(selected: NativeDestination, onSelected: (NativeDestination) -> Unit) {
    val entries = listOf(
        NativeDestination.TODAY to Icons.Outlined.Home,
        NativeDestination.TIMETABLE to Icons.Outlined.CalendarMonth,
        NativeDestination.GRADES to Icons.Outlined.School,
        NativeDestination.SETTINGS to Icons.Outlined.Settings,
    )
    NavigationBar {
        entries.forEach { (destination, icon) ->
            NavigationBarItem(selected = selected == destination, onClick = { onSelected(destination) }, icon = { Icon(icon, null) }, label = { Text(destination.title) })
        }
    }
}

@Composable
private fun TodayScreen(api: HandHelperApi, accessToken: String, padding: PaddingValues) {
    var name by remember { mutableStateOf("同学") }
    var message by remember { mutableStateOf("正在连接个人服务…") }
    var loading by remember { mutableStateOf(true) }
    fun refresh() {
        loading = true
    }
    LaunchedEffect(loading) {
        if (loading) {
            api.profile(accessToken).onSuccess { name = it.displayName; message = "服务连接正常" }.onFailure { message = "暂时无法读取个人资料：${it.message ?: "网络异常"}" }
            loading = false
        }
    }
    Column(modifier = Modifier.fillMaxSize().padding(padding).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("你好，$name", style = MaterialTheme.typography.headlineMedium)
        ElevatedCard(colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
            Column(Modifier.fillMaxWidth().padding(20.dp)) {
                Text("今日", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.height(8.dp))
                Text("原生 Android 预览已启用", style = MaterialTheme.typography.bodyLarge)
                Spacer(Modifier.height(6.dp))
                Text(message)
            }
        }
        Button(onClick = ::refresh, enabled = !loading) { Text(if (loading) "连接中…" else "刷新状态") }
    }
}

@Composable
private fun NativeInfoScreen(title: String, message: String, padding: PaddingValues) {
    Column(modifier = Modifier.fillMaxSize().padding(padding).padding(20.dp)) {
        ElevatedCard { Column(Modifier.fillMaxWidth().padding(20.dp)) { Text(title, style = MaterialTheme.typography.titleLarge); Spacer(Modifier.height(10.dp)); Text(message) } }
    }
}

@Composable
private fun TimetableScreen(api: HandHelperApi, accessToken: String, padding: PaddingValues) {
    var terms by remember { mutableStateOf<List<AcademicTerm>>(emptyList()) }
    var selectedTermId by rememberSaveable { mutableStateOf<Int?>(null) }
    var weekNumber by rememberSaveable { mutableStateOf(1) }
    var sessions by remember { mutableStateOf<List<TimetableSession>>(emptyList()) }
    var loadingTerms by remember { mutableStateOf(true) }
    var loadingSessions by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        api.terms(accessToken).onSuccess { loadedTerms ->
            terms = loadedTerms
            selectedTermId = loadedTerms.firstOrNull { it.isCurrent }?.id
                ?: loadedTerms.lastOrNull { it.startDate != null }?.id
                ?: loadedTerms.firstOrNull()?.id
        }.onFailure { throwable ->
            error = throwable.message ?: "无法读取学期"
        }
        loadingTerms = false
    }

    val selectedTerm = terms.firstOrNull { it.id == selectedTermId }
    LaunchedEffect(selectedTermId, weekNumber) {
        val term = selectedTerm ?: return@LaunchedEffect
        val firstMonday = term.startDate
        if (firstMonday == null) {
            sessions = emptyList()
            error = "该学期尚未配置第一周周一日期"
            return@LaunchedEffect
        }
        loadingSessions = true
        error = null
        val weekStart = shiftDate(firstMonday, (weekNumber - 1) * 7)
        api.timetableWeek(accessToken, weekStart).onSuccess { loadedSessions ->
            sessions = loadedSessions.filter { it.termId == term.id }
        }.onFailure { throwable ->
            sessions = emptyList()
            error = throwable.message ?: "无法读取课程表"
        }
        loadingSessions = false
    }

    Column(modifier = Modifier.fillMaxSize().padding(padding)) {
        if (loadingTerms) {
            Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator()
                Spacer(Modifier.height(12.dp))
                Text("正在读取学期…")
            }
            return@Column
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item {
                Text("选择学期", style = MaterialTheme.typography.labelLarge)
                Spacer(Modifier.height(8.dp))
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(terms, key = { it.id }) { term ->
                        FilterChip(
                            selected = term.id == selectedTermId,
                            onClick = { selectedTermId = term.id; weekNumber = 1 },
                            label = { Text(term.displayName) },
                        )
                    }
                }
            }
            item {
                ElevatedCard {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        TextButton(onClick = { if (weekNumber > 1) weekNumber-- }, enabled = weekNumber > 1 && !loadingSessions) { Text("上一周") }
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("第 $weekNumber 周", style = MaterialTheme.typography.titleLarge)
                            Text(selectedTerm?.displayName ?: "未选择学期", style = MaterialTheme.typography.bodySmall)
                        }
                        TextButton(onClick = { weekNumber++ }, enabled = !loadingSessions) { Text("下一周") }
                    }
                }
            }
            if (loadingSessions) {
                item { Column(Modifier.fillMaxWidth().padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally) { CircularProgressIndicator(); Spacer(Modifier.height(10.dp)); Text("正在读取本周课程…") } }
            } else if (error != null) {
                item { ElevatedCard { Text(error!!, modifier = Modifier.padding(18.dp), color = MaterialTheme.colorScheme.error) } }
            } else if (selectedTerm == null) {
                item { EmptyTimetableCard("当前没有可用学期") }
            } else if (sessions.isEmpty()) {
                item { EmptyTimetableCard("第 $weekNumber 周暂无课程") }
            } else {
                val groupedSessions = sessions.groupBy { it.sessionDate }.toSortedMap()
                groupedSessions.forEach { (date, dailySessions) ->
                    item(key = "header-$date") { Text(formatDateTitle(date), style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 4.dp)) }
                    items(dailySessions.sortedBy { it.startDateTime }, key = { it.id }) { session -> TimetableSessionCard(session) }
                }
            }
        }
    }
}

@Composable
private fun EmptyTimetableCard(message: String) {
    ElevatedCard { Text(message, modifier = Modifier.fillMaxWidth().padding(30.dp), style = MaterialTheme.typography.bodyLarge) }
}

@Composable
private fun TimetableSessionCard(session: TimetableSession) {
    ElevatedCard(colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
        Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(session.courseName, style = MaterialTheme.typography.titleMedium)
            Text("${formatClock(session.startDateTime)} — ${formatClock(session.endDateTime)}")
            session.classroom?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
            session.teacher?.let { Text("教师：$it", style = MaterialTheme.typography.bodySmall) }
            session.weekExpression?.let { Text("周次：$it", style = MaterialTheme.typography.bodySmall) }
        }
    }
}

private fun shiftDate(date: String, dayOffset: Int): String {
    val formatter = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { isLenient = false }
    val parsed = formatter.parse(date) ?: Date()
    return formatter.format(Calendar.getInstance().apply { time = parsed; add(Calendar.DAY_OF_YEAR, dayOffset) }.time)
}

private fun formatDateTitle(date: String): String {
    val formatter = SimpleDateFormat("yyyy-MM-dd", Locale.US)
    val parsed = runCatching { formatter.parse(date) }.getOrNull() ?: return date
    return SimpleDateFormat("M月d日 EEEE", Locale.CHINA).format(parsed)
}

private fun formatClock(dateTime: String): String = dateTime.substringAfter('T', dateTime).take(5)

@Composable
private fun GradesScreen(api: HandHelperApi, accessToken: String, padding: PaddingValues) {
    var terms by remember { mutableStateOf<List<AcademicTerm>>(emptyList()) }
    var selectedTermId by rememberSaveable { mutableStateOf<Int?>(null) }
    var grades by remember { mutableStateOf<List<GradeItem>>(emptyList()) }
    var summary by remember { mutableStateOf<GradeSummary?>(null) }
    var loadingTerms by remember { mutableStateOf(true) }
    var loadingGrades by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        api.terms(accessToken).onSuccess { loadedTerms ->
            terms = loadedTerms
            selectedTermId = loadedTerms.firstOrNull { it.isCurrent }?.id
                ?: loadedTerms.lastOrNull()?.id
        }.onFailure { throwable -> error = throwable.message ?: "无法读取学期" }
        loadingTerms = false
    }
    LaunchedEffect(selectedTermId) {
        val termId = selectedTermId ?: return@LaunchedEffect
        loadingGrades = true
        error = null
        api.grades(accessToken, termId).onSuccess { grades = it }.onFailure { throwable -> error = throwable.message ?: "无法读取成绩" }
        api.gradeSummary(accessToken, termId).onSuccess { summary = it }.onFailure { throwable -> if (error == null) error = throwable.message ?: "无法读取成绩汇总" }
        loadingGrades = false
    }

    Column(modifier = Modifier.fillMaxSize().padding(padding)) {
        if (loadingTerms) {
            Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) { CircularProgressIndicator(); Spacer(Modifier.height(12.dp)); Text("正在读取学期…") }
            return@Column
        }
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item {
                Text("选择学期", style = MaterialTheme.typography.labelLarge)
                Spacer(Modifier.height(8.dp))
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(terms, key = { it.id }) { term ->
                        FilterChip(selected = term.id == selectedTermId, onClick = { selectedTermId = term.id }, label = { Text(term.displayName) })
                    }
                }
            }
            summary?.let { value -> item { GradeSummaryCard(value) } }
            if (loadingGrades) {
                item { Column(Modifier.fillMaxWidth().padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally) { CircularProgressIndicator(); Spacer(Modifier.height(10.dp)); Text("正在读取成绩…") } }
            } else if (error != null) {
                item { ElevatedCard { Text(error!!, modifier = Modifier.padding(18.dp), color = MaterialTheme.colorScheme.error) } }
            } else if (selectedTermId == null) {
                item { EmptyTimetableCard("当前没有可用学期") }
            } else if (grades.isEmpty()) {
                item { EmptyTimetableCard("该学期暂未导入成绩") }
            } else {
                items(grades, key = { it.id }) { grade -> GradeCard(grade) }
            }
        }
    }
}

@Composable
private fun GradeSummaryCard(summary: GradeSummary) {
    ElevatedCard(colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
        Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("成绩概览", style = MaterialTheme.typography.titleMedium)
            Text("${summary.totalCourses} 门课程 · 已获 ${summary.earnedCredits.prettyNumber()} 学分")
            Text("平均成绩：${summary.averageScore?.prettyNumber() ?: "—"}    绩点：${summary.gpa?.let { String.format(Locale.US, "%.2f", it) } ?: "—"}")
            Text("不及格：${summary.failedCourses} 门", style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun GradeCard(grade: GradeItem) {
    ElevatedCard {
        Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(grade.courseName, style = MaterialTheme.typography.titleMedium)
            Text("成绩：${grade.score ?: "—"}    学分：${grade.credits?.prettyNumber() ?: "—"}")
            Text("绩点：${grade.gradePoint?.prettyNumber() ?: "—"}", style = MaterialTheme.typography.bodyMedium)
            val details = listOfNotNull(grade.courseType, grade.examType).joinToString(" · ")
            if (details.isNotBlank()) Text(details, style = MaterialTheme.typography.bodySmall)
        }
    }
}

private fun Double.prettyNumber(): String = if (this % 1.0 == 0.0) toInt().toString() else String.format(Locale.US, "%.1f", this)

@Composable
private fun SettingsScreen(api: HandHelperApi, accessToken: String, padding: PaddingValues, onLogout: () -> Unit) {
    var health by remember { mutableStateOf("正在检查服务器…") }
    LaunchedEffect(Unit) { api.checkSession(accessToken).onSuccess { health = "服务器连接正常" }.onFailure { health = "服务器不可用：${it.message ?: "网络异常"}" } }
    Column(modifier = Modifier.fillMaxSize().padding(padding).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ElevatedCard { Column(Modifier.fillMaxWidth().padding(20.dp)) { Text("服务器", style = MaterialTheme.typography.titleLarge); Spacer(Modifier.height(8.dp)); Text(health) } }
        ElevatedCard { Column(Modifier.fillMaxWidth().padding(20.dp)) { Text("安全存储", style = MaterialTheme.typography.titleLarge); Spacer(Modifier.height(8.dp)); Text("登录令牌已使用 Android 加密存储；应用不会保存账号密码。") } }
        Button(onClick = onLogout) { Text("退出当前账号") }
    }
}

private object PreviewData {
    val terms = listOf(
        AcademicTerm(1, "2026-2027-1", "2026-09-07", true),
        AcademicTerm(2, "2025-2026-2", "2026-03-02", false),
    )
    val sessions = listOf(
        TimetableSession(1, "开源大数据技术", "2026-09-07", "2026-09-07T08:30", "2026-09-07T10:05", "汇学楼4幢副203（多媒体）", "熊文（副教授）", "1-18周", 1),
        TimetableSession(2, "开源大数据技术", "2026-09-07", "2026-09-07T10:25", "2026-09-07T12:00", "睿智楼4幢311（软件实验室3）", "熊文（副教授）", "1-18周", 1),
        TimetableSession(3, "机器学习", "2026-09-09", "2026-09-09T13:40", "2026-09-09T15:15", "汇学楼4幢副201（多媒体）", "张云港（副教授）", "1-16周", 1),
        TimetableSession(4, "Python数据分析与可视化技术", "2026-09-10", "2026-09-10T15:30", "2026-09-10T17:15", "睿智楼4幢211（软件实验室1）", "刘平（讲师）", "1-16周", 1),
    )
    val grades = listOf(
        GradeItem(1, 2, "数据库技术", "专业限选课程", 3.0, "89", 3.9, "正常考试"),
        GradeItem(2, 2, "计算机组成原理", "专业核心课程", 4.0, "75", 2.5, "正常考试"),
        GradeItem(3, 2, "形势与政策（四）", "通识必修课程", 0.3, "96", 4.0, "正常考试"),
        GradeItem(4, 2, "大学体育（4）", "通识必修课程", 1.0, "88", 3.8, "正常考试"),
    )
    val gradeSummary = GradeSummary(4, 8.3, 87.0, 3.55, 0)
}

@Composable
private fun PreviewTodayScreen(padding: PaddingValues) {
    var showAddSchedule by rememberSaveable { mutableStateOf(false) }
    var schedules by remember { mutableStateOf(listOf("19:00  完成实验报告")) }
    if (showAddSchedule) {
        PreviewScheduleDialog(
            onDismiss = { showAddSchedule = false },
            onSave = { title, time -> schedules = schedules + "$time  $title"; showAddSchedule = false },
        )
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(padding),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            val dark = androidx.compose.foundation.isSystemInDarkTheme()
            val heroShape = RoundedCornerShape(24.dp)
            val heroBrush = if (dark) {
                Brush.linearGradient(listOf(Color(0xFF1B2A43), Color(0xFF263B59), Color(0xFF1A293A)))
            } else {
                Brush.linearGradient(listOf(Color(0xFFE7F0FA), Color(0xFFF6F8F6), Color(0xFFDCEBD4)))
            }
            Box(
                modifier = Modifier.fillMaxWidth().height(212.dp).clip(heroShape).background(heroBrush).border(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .45f), heroShape),
            ) {
                Row(
                    modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp, vertical = 22.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(11.dp)) {
                        Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surface.copy(alpha = .72f)) {
                            Text("今日 · 晚上好", modifier = Modifier.padding(horizontal = 11.dp, vertical = 5.dp), style = MaterialTheme.typography.labelLarge)
                        }
                        Text("用户", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.SemiBold)
                        Surface(shape = RoundedCornerShape(11.dp), color = MaterialTheme.colorScheme.surface.copy(alpha = .68f)) {
                            Text("8月22日星期六", modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp), style = MaterialTheme.typography.labelLarge)
                        }
                    }
                    Surface(
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = .8f),
                        border = androidx.compose.foundation.BorderStroke(3.dp, MaterialTheme.colorScheme.surface.copy(alpha = .9f)),
                        shadowElevation = 7.dp,
                    ) {
                        Box(Modifier.size(82.dp), contentAlignment = Alignment.Center) {
                            Text("航", style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
        }
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text("今日安排", style = MaterialTheme.typography.titleLarge)
                TextButton(onClick = { showAddSchedule = true }) { Text("＋ 添加安排") }
            }
        }
        item { PreviewAgendaCard("08:30", "开源大数据技术", "汇学楼4幢副203 · 熊文") }
        item { PreviewAgendaCard("13:40", "机器学习", "汇学楼4幢副201 · 张云港") }
        items(schedules, key = { it }) { schedule -> PreviewAgendaCard(schedule.substringBefore("  "), schedule.substringAfterLast("  "), "自定义安排 · 本地预览") }
    }
}

@Composable
private fun PreviewAgendaCard(time: String, title: String, subtitle: String) {
    val cardShape = RoundedCornerShape(18.dp)
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = cardShape,
        color = MaterialTheme.colorScheme.surface,
        shadowElevation = 2.dp,
        border = androidx.compose.foundation.BorderStroke(
            1.dp,
            MaterialTheme.colorScheme.outlineVariant.copy(alpha = .28f),
        ),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = .58f),
            ) {
                Text(
                    time,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
                    color = MaterialTheme.colorScheme.primary,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Spacer(Modifier.width(14.dp))
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun PreviewScheduleDialog(onDismiss: () -> Unit, onSave: (String, String) -> Unit) {
    var title by rememberSaveable { mutableStateOf("") }
    var time by rememberSaveable { mutableStateOf("19:00") }
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        val sheetShape = RoundedCornerShape(26.dp)
        Surface(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp),
            shape = sheetShape,
            color = MaterialTheme.colorScheme.surface,
            shadowElevation = 18.dp,
        ) {
            Column(
                modifier = Modifier.padding(horizontal = 22.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(13.dp),
            ) {
                Spacer(
                    modifier = Modifier.fillMaxWidth().height(4.dp).clip(CircleShape)
                        .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = .8f)),
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Text("添加安排", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
                    Surface(
                        modifier = Modifier.clickable(onClick = onDismiss),
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.primaryContainer,
                    ) { Text("×", modifier = Modifier.padding(horizontal = 12.dp, vertical = 5.dp), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.titleLarge) }
                }
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("安排事项", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelLarge)
                    OutlinedTextField(
                        value = title,
                        onValueChange = { title = it },
                        placeholder = { Text("例如：提交课程作业") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(14.dp),
                    )
                }
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("时间", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelLarge)
                    OutlinedTextField(
                        value = time,
                        onValueChange = { time = it },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(14.dp),
                    )
                }
                Text("当前仅用于原生页面预览；保存接口将在视觉确认后接入。", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = onDismiss) { Text("取消") }
                    Spacer(Modifier.width(8.dp))
                    Button(onClick = { if (title.isNotBlank()) onSave(title, time) }) { Text("保存安排") }
                }
            }
        }
    }
}

@Composable
private fun PreviewTimetableScreen(padding: PaddingValues) {
    var termId by rememberSaveable { mutableStateOf(1) }
    var week by rememberSaveable { mutableStateOf(1) }
    var selectedSession by remember { mutableStateOf<TimetableSession?>(null) }
    var highlightedSlot by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    var addCourseSlot by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    var manualSessions by remember { mutableStateOf<List<TimetableSession>>(emptyList()) }
    val selectedTerm = PreviewData.terms.first { it.id == termId }
    addCourseSlot?.let { (dayIndex, period) ->
        PreviewAddCourseScreen(
            padding = padding,
            termName = selectedTerm.displayName,
            initialWeek = week,
            initialDayIndex = dayIndex,
            initialPeriod = period,
            onBack = { addCourseSlot = null },
            onSave = { name, classroom, teacher, weeks, selectedDayIndex, startPeriod, endPeriod ->
                val date = listOf("2026-09-07", "2026-09-08", "2026-09-09", "2026-09-10", "2026-09-11")[selectedDayIndex]
                val startTime = previewPeriodBounds(startPeriod).first
                val endTime = previewPeriodBounds(endPeriod).second
                manualSessions = manualSessions + weeks.sorted().mapIndexed { index, selectedWeek ->
                    TimetableSession(
                        id = 1000 + manualSessions.size + index,
                        courseName = name,
                        sessionDate = date,
                        startDateTime = "${date}T${startTime}",
                        endDateTime = "${date}T${endTime}",
                        classroom = classroom.ifBlank { "待填写教室" },
                        teacher = teacher.ifBlank { "待填写教师" },
                        weekExpression = "第${selectedWeek}周",
                        termId = termId,
                    )
                }
                highlightedSlot = null
                addCourseSlot = null
            },
        )
        return
    }
    val sessions = buildList {
        if (week == 1) addAll(PreviewData.sessions.filter { it.termId == termId })
        addAll(manualSessions.filter { it.termId == termId && it.weekExpression == "第${week}周" })
    }
    selectedSession?.let { session ->
        PreviewCourseDetailDialog(session = session, onDismiss = { selectedSession = null })
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(padding),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 3.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Text("课程表", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Surface(shape = CircleShape, color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = .7f)) {
                        Text("↻", modifier = Modifier.padding(9.dp), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.titleMedium)
                    }
                }
                Text("按周查看课程安排", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            }
        }
        item {
            Surface(shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surface, shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .3f))) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = { if (week > 1) week-- }, enabled = week > 1) { Text("‹") }
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(if (week == 1) "第 1 周" else "第 $week 周", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                            Text(selectedTerm.displayName, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall)
                        }
                        TextButton(onClick = { if (week < 20) week++ }) { Text("›") }
                    }
                    PreviewWeekGrid(
                        sessions = sessions,
                        week = week,
                        highlightedSlot = highlightedSlot,
                        onCourseClick = { selectedSession = it },
                        onEmptySlotClick = { dayIndex, period ->
                            val tappedSlot = dayIndex to period
                            if (highlightedSlot == tappedSlot) {
                                addCourseSlot = tappedSlot
                            } else {
                                highlightedSlot = tappedSlot
                            }
                        },
                    )
                }
            }
        }
        item {
            Text("学期", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelLarge)
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 7.dp)) {
                items(PreviewData.terms, key = { it.id }) { term ->
                    FilterChip(
                        selected = term.id == termId,
                        onClick = { termId = term.id; week = 1 },
                        label = { Text(term.displayName) },
                    )
                }
            }
        }
    }
}

@Composable
private fun PreviewWeekGrid(
    sessions: List<TimetableSession>,
    week: Int,
    highlightedSlot: Pair<Int, Int>?,
    onCourseClick: (TimetableSession) -> Unit,
    onEmptySlotClick: (dayIndex: Int, period: Int) -> Unit,
) {
    val days = listOf("一" to "7", "二" to "8", "三" to "9", "四" to "10", "五" to "11")
    val periodTimes = listOf(
        "08:30\n09:15", "09:20\n10:05", "10:25\n11:10", "11:15\n12:00",
        "13:40\n14:25", "14:30\n15:15", "15:30\n16:15", "16:30\n17:15",
        "17:20\n18:05", "18:20\n19:05", "19:10\n19:55", "20:00\n20:45", "20:50\n21:35",
    )
    val sessionPositions = sessions.mapNotNull { session ->
        val dayIndex = when (session.sessionDate) {
            "2026-09-07" -> 0
            "2026-09-08" -> 1
            "2026-09-09" -> 2
            "2026-09-10" -> 3
            "2026-09-11" -> 4
            else -> null
        } ?: return@mapNotNull null
        val startPeriod = when (session.startDateTime.substringAfter('T').take(5)) {
            "08:30" -> 1; "09:20" -> 2; "10:25" -> 3; "11:15" -> 4; "13:40" -> 5; "14:30" -> 6; "15:30" -> 7; "16:30" -> 8; "17:20" -> 9; "18:20" -> 10; "19:10" -> 11; "20:00" -> 12; "20:50" -> 13; else -> 1
        }
        val endPeriod = when (session.endDateTime.substringAfter('T').take(5)) {
            "09:15" -> 1; "10:05" -> 2; "11:10" -> 3; "12:00" -> 4; "14:25" -> 5; "15:15" -> 6; "16:15" -> 7; "17:15" -> 8; "18:05" -> 9; "19:05" -> 10; "19:55" -> 11; "20:45" -> 12; "21:35" -> 13; else -> startPeriod
        }
        Triple(session, dayIndex, startPeriod to endPeriod)
    }
    // 课程格宽度永远由当前屏幕可用宽度计算：五个工作日必须同屏可见。
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val timeColumnWidth = 40.dp
        val cellWidth = (maxWidth - timeColumnWidth) / days.size
        val rowHeight = 62.dp
        val gridHeight = rowHeight * periodTimes.size
        Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
            Row(Modifier.fillMaxWidth()) {
                Spacer(Modifier.width(timeColumnWidth))
                Row(Modifier.width(cellWidth * days.size)) {
                days.forEach { (weekday, day) ->
                        Column(Modifier.width(cellWidth), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(weekday, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                            Text(day, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
            }
            Row(Modifier.fillMaxWidth()) {
                Column(Modifier.width(timeColumnWidth).height(gridHeight)) {
                    periodTimes.forEachIndexed { index, time ->
                        Column(Modifier.height(rowHeight).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(1.dp)) {
                            Text("${index + 1}", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                            Text(time, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall, textAlign = TextAlign.Center)
                        }
                    }
                }
                Box(
                    Modifier.width(cellWidth * days.size).height(gridHeight)
                        .border(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .35f)),
                ) {
                    Column(Modifier.fillMaxSize()) {
                        repeat(periodTimes.size) {
                            Spacer(Modifier.fillMaxWidth().height(rowHeight).border(0.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .25f)))
                        }
                    }
                    Row(Modifier.fillMaxSize()) {
                        repeat(days.size) {
                            Spacer(Modifier.width(cellWidth).fillMaxHeight().border(0.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .2f)))
                        }
                    }
                    // 透明点击层只覆盖未被课程占用的格子；课程卡在下一层绘制，优先响应详情点击。
                    repeat(days.size) { dayIndex ->
                        repeat(periodTimes.size) { periodIndex ->
                            val occupied = sessionPositions.any { (_, sessionDay, range) ->
                                sessionDay == dayIndex && periodIndex + 1 in range.first..range.second
                            }
                            if (!occupied) {
                                Surface(
                                    onClick = { onEmptySlotClick(dayIndex, periodIndex + 1) },
                                    modifier = Modifier.offset(x = cellWidth * dayIndex, y = rowHeight * periodIndex)
                                        .width(cellWidth).height(rowHeight),
                                    color = Color.Transparent,
                                ) {}
                            }
                        }
                    }
                    highlightedSlot?.let { (dayIndex, period) ->
                        val occupied = sessionPositions.any { (_, sessionDay, range) ->
                            sessionDay == dayIndex && period in range.first..range.second
                        }
                        if (!occupied) {
                            Surface(
                                onClick = { onEmptySlotClick(dayIndex, period) },
                                modifier = Modifier.offset(x = cellWidth * dayIndex + 2.dp, y = rowHeight * (period - 1) + 2.dp)
                                    .width(cellWidth - 4.dp).height(rowHeight - 4.dp),
                                shape = RoundedCornerShape(10.dp),
                                color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = .65f),
                                border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = .48f)),
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Text("＋", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.headlineSmall)
                                }
                            }
                        }
                    }
                    sessionPositions.forEach { (session, dayIndex, range) ->
                        val start = range.first
                        val end = range.second
                        val accent = courseAccent(session.courseName)
                        Surface(
                            onClick = { onCourseClick(session) },
                            modifier = Modifier.offset(x = cellWidth * dayIndex + 2.dp, y = rowHeight * (start - 1) + 2.dp)
                                .width(cellWidth - 4.dp).height(rowHeight * (end - start + 1) - 4.dp),
                            shape = RoundedCornerShape(9.dp),
                            color = accent.copy(alpha = .2f),
                            border = androidx.compose.foundation.BorderStroke(1.dp, accent.copy(alpha = .38f)),
                        ) {
                            Column(Modifier.padding(5.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(session.courseName, color = accent, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.labelSmall, maxLines = 2)
                                Text(session.classroom.orEmpty().replace("（", "\n（"), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall, maxLines = 2)
                            }
                        }
                    }
                    if (week != 1) {
                        Text("本周暂无课程", modifier = Modifier.align(Alignment.Center), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
        }
    }
}

/**
 * 课程详情沿用网页端的底部信息卡层级；这里的课程数据仍是本地预览状态，
 * 因而不提供编辑或删除等会写入真实课表的操作。
 */
@Composable
private fun PreviewCourseDetailDialog(session: TimetableSession, onDismiss: () -> Unit) {
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp),
            shape = RoundedCornerShape(25.dp),
            color = MaterialTheme.colorScheme.surface,
            shadowElevation = 18.dp,
        ) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.fillMaxWidth()) {
                    Surface(
                        modifier = Modifier.align(Alignment.TopCenter).width(40.dp).height(4.dp),
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.outlineVariant,
                    ) {}
                    Surface(
                        onClick = onDismiss,
                        modifier = Modifier.align(Alignment.TopEnd).size(36.dp),
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = .7f),
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Text("×", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.titleLarge)
                        }
                    }
                }
                Text(session.courseName, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                PreviewCourseDetailRow(
                    label = "上课时间",
                    value = "${session.sessionDate} ${session.startDateTime.substringAfter('T').take(5)}—${session.endDateTime.substringAfter('T').take(5)}",
                )
                PreviewCourseDetailRow(label = "教室", value = session.classroom ?: "未填写")
                PreviewCourseDetailRow(label = "教师", value = session.teacher ?: "未填写")
                PreviewCourseDetailRow(label = "周次", value = session.weekExpression ?: "未填写", drawDivider = false)
            }
        }
    }
}

@Composable
private fun PreviewCourseDetailRow(label: String, value: String, drawDivider: Boolean = true) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelLarge)
        Text(value, style = MaterialTheme.typography.bodyLarge)
        if (drawDivider) {
            Spacer(
                Modifier.fillMaxWidth().height(1.dp)
                    .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = .55f)),
            )
        }
    }
}

/** 添加课程为独立页面；底部选择器仅负责选择周次或具体上课节数。 */
@Composable
private fun PreviewAddCourseScreen(
    padding: PaddingValues,
    termName: String,
    initialWeek: Int,
    initialDayIndex: Int,
    initialPeriod: Int,
    onBack: () -> Unit,
    onSave: (
        name: String,
        classroom: String,
        teacher: String,
        weeks: Set<Int>,
        dayIndex: Int,
        startPeriod: Int,
        endPeriod: Int,
    ) -> Unit,
) {
    var courseName by rememberSaveable { mutableStateOf("") }
    var classroom by rememberSaveable { mutableStateOf("") }
    var teacher by rememberSaveable { mutableStateOf("") }
    var weeks by remember { mutableStateOf(setOf(initialWeek)) }
    var dayIndex by rememberSaveable { mutableStateOf(initialDayIndex) }
    var startPeriod by rememberSaveable { mutableStateOf(initialPeriod) }
    var endPeriod by rememberSaveable { mutableStateOf(initialPeriod) }
    var showWeekPicker by rememberSaveable { mutableStateOf(false) }
    var showTimePicker by rememberSaveable { mutableStateOf(false) }
    val dayName = previewWeekdays[dayIndex]
    val time = previewPeriodBounds(startPeriod).first to previewPeriodBounds(endPeriod).second

    BackHandler(onBack = onBack)
    if (showWeekPicker) {
        PreviewWeekPickerDialog(
            initialWeeks = weeks,
            onDismiss = { showWeekPicker = false },
            onDone = { selectedWeeks ->
                weeks = selectedWeeks
                showWeekPicker = false
            },
        )
    }
    if (showTimePicker) {
        PreviewCourseTimePickerDialog(
            initialDayIndex = dayIndex,
            initialStartPeriod = startPeriod,
            initialEndPeriod = endPeriod,
            onDismiss = { showTimePicker = false },
            onDone = { selectedDayIndex, selectedStartPeriod, selectedEndPeriod ->
                dayIndex = selectedDayIndex
                startPeriod = selectedStartPeriod
                endPeriod = selectedEndPeriod
                showTimePicker = false
            },
        )
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(padding),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(13.dp),
    ) {
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack) { Text("‹ 返回") }
                Text("添加课程", modifier = Modifier.weight(1f), textAlign = TextAlign.Center, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                TextButton(
                    onClick = {
                        if (courseName.isNotBlank()) {
                            onSave(courseName.trim(), classroom.trim(), teacher.trim(), weeks, dayIndex, startPeriod, endPeriod)
                        }
                    },
                ) { Text("保存") }
            }
        }
        item {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(18.dp),
                color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = .5f),
            ) {
                Row(Modifier.padding(15.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Column {
                        Text("当前学期", color = MaterialTheme.colorScheme.onPrimaryContainer, style = MaterialTheme.typography.labelLarge)
                        Text(termName, color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    }
                    Text("本地预览", color = MaterialTheme.colorScheme.onPrimaryContainer, style = MaterialTheme.typography.labelSmall)
                }
            }
        }
        item {
            OutlinedTextField(
                value = courseName,
                onValueChange = { courseName = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("课程名称") },
                placeholder = { Text("请输入课程名称") },
                singleLine = true,
            )
        }
        item {
            PreviewSelectorRow(
                label = "上课周次",
                value = "已选 ${weeks.size} / 20 周",
                detail = previewWeekSummary(weeks),
                onClick = { showWeekPicker = true },
            )
        }
        item {
            PreviewSelectorRow(
                label = "课程节数",
                value = "$dayName｜第 $startPeriod${if (endPeriod != startPeriod) "–$endPeriod" else ""} 节",
                detail = "${time.first}–${time.second}",
                onClick = { showTimePicker = true },
            )
        }
        item {
            OutlinedTextField(
                value = classroom,
                onValueChange = { classroom = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("教室地点（可留空）") },
                singleLine = true,
            )
        }
        item {
            OutlinedTextField(
                value = teacher,
                onValueChange = { teacher = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("任课教师（可留空）") },
                singleLine = true,
            )
        }
        item {
            Text(
                "保存后将显示在本地原生预览课表中；待页面设计确认后再接入真实保存接口。",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
        }
        item {
            Button(
                onClick = {
                    if (courseName.isNotBlank()) {
                        onSave(courseName.trim(), classroom.trim(), teacher.trim(), weeks, dayIndex, startPeriod, endPeriod)
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("保存课程") }
        }
    }
}

@Composable
private fun PreviewSelectorRow(label: String, value: String, detail: String, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        shadowElevation = 1.dp,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .45f)),
    ) {
        Row(Modifier.padding(horizontal = 15.dp, vertical = 13.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(label, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            }
            Text(value, color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
            Text("›", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(start = 8.dp))
        }
    }
}

/** 20 周全部同屏展示，支持全选、单周、双周与逐格选择。 */
@Composable
private fun PreviewWeekPickerDialog(
    initialWeeks: Set<Int>,
    onDismiss: () -> Unit,
    onDone: (Set<Int>) -> Unit,
) {
    var selectedWeeks by remember(initialWeeks) { mutableStateOf(initialWeeks) }
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            shape = RoundedCornerShape(26.dp),
            color = MaterialTheme.colorScheme.surface,
            shadowElevation = 20.dp,
        ) {
            Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.fillMaxWidth()) {
                    Surface(
                        modifier = Modifier.align(Alignment.TopCenter).width(40.dp).height(4.dp),
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.outlineVariant,
                    ) {}
                    TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.TopStart)) { Text("取消") }
                    TextButton(onClick = { onDone(selectedWeeks) }, modifier = Modifier.align(Alignment.TopEnd)) { Text("完成") }
                }
                Text("上课周次", modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Text("已选择 ${selectedWeeks.size} / 20 周", modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    PreviewWeekQuickAction("全选", Modifier.weight(1f)) { selectedWeeks = (1..20).toSet() }
                    PreviewWeekQuickAction("单周", Modifier.weight(1f)) { selectedWeeks = (1..20).filter { it % 2 == 1 }.toSet() }
                    PreviewWeekQuickAction("双周", Modifier.weight(1f)) { selectedWeeks = (1..20).filter { it % 2 == 0 }.toSet() }
                    PreviewWeekQuickAction("清空", Modifier.weight(1f)) { selectedWeeks = emptySet() }
                }
                (1..20).chunked(5).forEach { rowWeeks ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                        rowWeeks.forEach { candidate ->
                            val selected = candidate in selectedWeeks
                            Surface(
                                onClick = {
                                    selectedWeeks = if (selected) selectedWeeks - candidate else selectedWeeks + candidate
                                },
                                modifier = Modifier.weight(1f).height(46.dp),
                                shape = RoundedCornerShape(12.dp),
                                color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.secondaryContainer.copy(alpha = .58f),
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Text(candidate.toString(), color = if (selected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSecondaryContainer, fontWeight = FontWeight.SemiBold)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PreviewWeekQuickAction(label: String, modifier: Modifier, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        modifier = modifier.height(38.dp),
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = .62f),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(label, color = MaterialTheme.colorScheme.onSecondaryContainer, style = MaterialTheme.typography.labelMedium)
        }
    }
}

/** 节次选择会继承点击空白格的位置，并允许更改星期与连续的起止节次。 */
@Composable
private fun PreviewCourseTimePickerDialog(
    initialDayIndex: Int,
    initialStartPeriod: Int,
    initialEndPeriod: Int,
    onDismiss: () -> Unit,
    onDone: (dayIndex: Int, startPeriod: Int, endPeriod: Int) -> Unit,
) {
    var dayIndex by rememberSaveable { mutableStateOf(initialDayIndex.coerceIn(0, previewWeekdays.lastIndex)) }
    // 防御性归一化：即使入口传入异常值，也绝不展示“开始节次晚于结束节次”。
    var startPeriod by rememberSaveable { mutableStateOf(minOf(initialStartPeriod, initialEndPeriod).coerceIn(1, 13)) }
    var endPeriod by rememberSaveable { mutableStateOf(maxOf(initialStartPeriod, initialEndPeriod).coerceIn(1, 13)) }
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            shape = RoundedCornerShape(26.dp),
            color = MaterialTheme.colorScheme.surface,
            shadowElevation = 20.dp,
        ) {
            Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(11.dp)) {
                Box(Modifier.fillMaxWidth()) {
                    Surface(
                        modifier = Modifier.align(Alignment.TopCenter).width(40.dp).height(4.dp),
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.outlineVariant,
                    ) {}
                    TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.TopStart)) { Text("取消") }
                    TextButton(onClick = { onDone(dayIndex, startPeriod, endPeriod) }, modifier = Modifier.align(Alignment.TopEnd)) { Text("完成") }
                }
                Text("上课时间", modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Text("${previewWeekdays[dayIndex]}｜第 $startPeriod${if (endPeriod != startPeriod) "–$endPeriod" else ""} 节｜${previewPeriodBounds(startPeriod).first}–${previewPeriodBounds(endPeriod).second}", modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                Text(
                    "滚动选择上课时间",
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.labelMedium,
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    PreviewPickerWheel(
                        title = "星期",
                        values = previewWeekdays,
                        selectedIndex = dayIndex,
                        modifier = Modifier.weight(1f),
                        onSelected = { dayIndex = it },
                    )
                    PreviewPickerWheel(
                        title = "开始节次",
                        values = (1..13).map { "第 $it 节" },
                        selectedIndex = startPeriod - 1,
                        modifier = Modifier.weight(1f),
                        onSelected = { index ->
                            val selected = index + 1
                            startPeriod = selected
                            // 开始向后移动时，结束节次随之移动，避免非法区间。
                            if (endPeriod < selected) endPeriod = selected
                        },
                    )
                    PreviewPickerWheel(
                        title = "结束节次",
                        values = (1..13).map { "第 $it 节" },
                        selectedIndex = endPeriod - 1,
                        modifier = Modifier.weight(1f),
                        onSelected = { index ->
                            val selected = index + 1
                            endPeriod = selected
                            // 结束向前移动时，开始节次随之移动，避免非法区间。
                            if (startPeriod > selected) startPeriod = selected
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun PreviewPickerWheel(
    title: String,
    values: List<String>,
    selectedIndex: Int,
    modifier: Modifier = Modifier,
    onSelected: (Int) -> Unit,
) {
    val itemHeight = 42.dp
    val wheelHeight = 150.dp
    // LazyColumn 的首项前留白必须刚好等于半个空白区；这样无论滚到哪一项，
    // 该项的文字中心都会落在中间的高亮槽，而不是偏上一格或下一格。
    val centerPadding = (wheelHeight - itemHeight) / 2
    // contentPadding 已经将未滚动的首项放到中央槽位。额外的 scrollOffset
    // 会让选中项整整错开一行，因此保持为 0。
    val centeredScrollOffset = 0
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = selectedIndex.coerceIn(0, values.lastIndex))
    val scope = rememberCoroutineScope()
    val latestSelectedIndex by rememberUpdatedState(selectedIndex)
    val latestOnSelected by rememberUpdatedState(onSelected)

    // 每次从入口带入的新节次都对齐到中线；用户松手后也会自动回正。
    LaunchedEffect(selectedIndex) {
        if (!listState.isScrollInProgress) {
            listState.animateScrollToItem(selectedIndex.coerceIn(0, values.lastIndex), centeredScrollOffset)
        }
    }
    LaunchedEffect(listState, values.size) {
        snapshotFlow { listState.isScrollInProgress }
            .filter { scrolling -> !scrolling }
            .collect {
                val layout = listState.layoutInfo
                val viewportCenter = (layout.viewportStartOffset + layout.viewportEndOffset) / 2
                val closest = layout.visibleItemsInfo.minByOrNull { item ->
                    abs((item.offset + item.size / 2) - viewportCenter)
                } ?: return@collect
                if (closest.index != latestSelectedIndex) latestOnSelected(closest.index)
                listState.animateScrollToItem(closest.index, centeredScrollOffset)
            }
    }

    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            title,
            modifier = Modifier.fillMaxWidth().padding(bottom = 5.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.labelSmall,
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(wheelHeight)
                .clip(RoundedCornerShape(16.dp))
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(16.dp)),
        ) {
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(itemHeight)
                    .align(Alignment.Center),
                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                shape = RoundedCornerShape(11.dp),
            ) {}
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(vertical = centerPadding),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                items(values.size) { index ->
                    val selected = index == selectedIndex
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(itemHeight)
                            .clickable {
                                onSelected(index)
                                scope.launch { listState.animateScrollToItem(index, centeredScrollOffset) }
                            }
                            .padding(horizontal = 3.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            values[index],
                            color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.62f),
                            textAlign = TextAlign.Center,
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                        )
                    }
                }
            }
        }
    }
}

private val previewWeekdays = listOf("周一", "周二", "周三", "周四", "周五")

private fun previewWeekSummary(weeks: Set<Int>): String {
    if (weeks.isEmpty()) return "尚未选择周次"
    val values = weeks.sorted()
    return if (values.size <= 5) values.joinToString("、", postfix = " 周") else "${values.take(4).joinToString("、")} 等 ${values.size} 周"
}

private fun previewPeriodBounds(period: Int): Pair<String, String> {
    val periods = listOf(
        "08:30" to "09:15", "09:20" to "10:05", "10:25" to "11:10", "11:15" to "12:00",
        "13:40" to "14:25", "14:30" to "15:15", "15:30" to "16:15", "16:30" to "17:15",
        "17:20" to "18:05", "18:20" to "19:05", "19:10" to "19:55", "20:00" to "20:45", "20:50" to "21:35",
    )
    return periods.getOrElse(period - 1) { periods.first() }
}

private fun courseAccent(name: String): Color = when {
    name.contains("开源") -> Color(0xFF6D4AFF)
    name.contains("机器") -> Color(0xFF0E7490)
    name.contains("Python") -> Color(0xFF0F8F6A)
    else -> Color(0xFF2563EB)
}

@Composable
private fun PreviewGradesScreen(padding: PaddingValues) {
    var termId by rememberSaveable { mutableStateOf(2) }
    val visibleGrades = PreviewData.grades.filter { it.termId == termId }
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(padding),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Text("成绩概览", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text("导入成绩后，在这里查看汇总与分析。", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 4.dp))
        }
        item {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(PreviewData.terms, key = { it.id }) { term ->
                    FilterChip(selected = term.id == termId, onClick = { termId = term.id }, label = { Text(term.displayName) })
                }
            }
        }
        if (termId == 2) item { PreviewGradeStatGrid(PreviewData.gradeSummary) }
        item {
            Surface(
                shape = RoundedCornerShape(18.dp),
                color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = .52f),
                border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = .28f)),
            ) {
                Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("AI 成绩分析", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text("将当前学期的课程名称、成绩、学分和绩点发送给已配置的模型服务。", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Surface(modifier = Modifier.weight(1f), shape = RoundedCornerShape(13.dp), color = MaterialTheme.colorScheme.surface.copy(alpha = .75f)) {
                            Text("历史分析", modifier = Modifier.padding(vertical = 11.dp), color = MaterialTheme.colorScheme.primary, textAlign = TextAlign.Center, style = MaterialTheme.typography.labelLarge)
                        }
                        Surface(modifier = Modifier.weight(1f), shape = RoundedCornerShape(13.dp), color = MaterialTheme.colorScheme.primary) {
                            Text("生成分析", modifier = Modifier.padding(vertical = 11.dp), color = MaterialTheme.colorScheme.onPrimary, textAlign = TextAlign.Center, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        }
        item { Text("课程成绩", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold) }
        if (visibleGrades.isEmpty()) item { EmptyTimetableCard("该学期暂未导入预览成绩") }
        items(visibleGrades, key = { it.id }) { PreviewGradeCard(it) }
    }
}

/** Web 端成绩卡的原生复刻：轻阴影、统一留白和紧凑的信息层级。 */
@Composable
private fun PreviewGradeCard(grade: GradeItem) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.surface,
        shadowElevation = 2.dp,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .18f)),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            Text(grade.courseName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                Text("成绩：${grade.score ?: "—"}", style = MaterialTheme.typography.bodyMedium)
                Text("学分：${grade.credits?.prettyNumber() ?: "—"}", style = MaterialTheme.typography.bodyMedium)
            }
            val details = buildList {
                grade.courseType?.let { add(it) }
                grade.gradePoint?.let { add("绩点：${it.prettyNumber()}") }
                grade.examType?.let { add(it) }
            }.joinToString(" · ")
            if (details.isNotBlank()) {
                Text(details, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun PreviewGradeStatGrid(summary: GradeSummary) {
    val stats = listOf(
        "已获学分" to summary.earnedCredits.prettyNumber(),
        "平均成绩" to (summary.averageScore?.prettyNumber() ?: "—"),
        "绩点" to (summary.gpa?.let { String.format(Locale.US, "%.2f", it) } ?: "—"),
        "不及格" to summary.failedCourses.toString(),
    )
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        stats.forEach { (label, value) ->
            Surface(
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(15.dp),
                color = MaterialTheme.colorScheme.surface,
                shadowElevation = 2.dp,
                border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .22f)),
            ) {
                Column(Modifier.padding(horizontal = 10.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall)
                    Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun PreviewSettingsScreen(padding: PaddingValues) {
    var mode by rememberSaveable { mutableStateOf("系统") }
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(padding),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Text("设置", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text("原生页面设计预览", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 4.dp))
        }
        item { PreviewSettingsCard("账号设置", "登录、凭据与账户安全") }
        item {
            Surface(
                shape = RoundedCornerShape(18.dp),
                color = MaterialTheme.colorScheme.surface,
                shadowElevation = 2.dp,
                border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .18f)),
            ) {
                Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("个性化设置", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text("外观模式", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    Surface(shape = RoundedCornerShape(15.dp), color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .62f)) {
                        Row(Modifier.fillMaxWidth().padding(4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            listOf("浅色", "深色", "系统").forEach { item ->
                                val selected = mode == item
                                Surface(
                                    modifier = Modifier.weight(1f).clickable { mode = item },
                                    shape = RoundedCornerShape(12.dp),
                                    color = if (selected) MaterialTheme.colorScheme.surface else Color.Transparent,
                                    shadowElevation = if (selected) 2.dp else 0.dp,
                                ) {
                                    Text(item, modifier = Modifier.padding(vertical = 10.dp), textAlign = TextAlign.Center, color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelLarge)
                                }
                            }
                        }
                    }
                }
            }
        }
        item { PreviewSettingsCard("时间设置", "学期第一周、节次时间与手动课程") }
        item { PreviewSettingsCard("数据与同步", "课程表和成绩导入、缓存与清理") }
        item { PreviewSettingsCard("关于助手", "航的助手 · Hand Helper") }
    }
}

@Composable
private fun PreviewSettingsCard(title: String, description: String) {
    val icon = when (title) {
        "时间设置" -> Icons.Outlined.CalendarMonth
        "数据与同步" -> Icons.Outlined.School
        "关于助手" -> Icons.Outlined.Settings
        else -> Icons.Outlined.Home
    }
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.surface,
        shadowElevation = 2.dp,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = .18f)),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(18.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Surface(modifier = Modifier.size(38.dp), shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.primaryContainer) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(description, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            }
            Text("›", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.titleLarge)
        }
    }
}
