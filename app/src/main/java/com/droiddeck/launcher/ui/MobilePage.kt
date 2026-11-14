package com.droiddeck.launcher.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Smartphone
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.droiddeck.launcher.R

@Composable
internal fun MobilePage(s: FrontEndState, a: FrontEndActions, modifier: Modifier) {
    val colors = MaterialTheme.colorScheme
    val narrow = LocalNarrowPane.current
    Column(
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = modifier.verticalScroll(rememberScrollState())
            .padding(horizontal = if (narrow) 20.dp else 44.dp, vertical = 44.dp),
    ) {
        Text(
            stringResource(R.string.rail_mobile), fontSize = 42.sp, lineHeight = 46.sp,
            fontWeight = FontWeight.Black, color = colors.onBackground,
        )
        BusyChip(s)
        Text(
            stringResource(R.string.mobile_about), fontSize = 15.sp, lineHeight = 21.sp,
            color = colors.onSurfaceVariant, modifier = Modifier.widthIn(max = 560.dp),
        )
        PrimaryButton(
            stringResource(R.string.mobile_open), enabled = !s.busy && s.ready, main = true, large = true,
            icon = Icons.Outlined.Smartphone, onClick = a.onMobile,
        )
    }
}
