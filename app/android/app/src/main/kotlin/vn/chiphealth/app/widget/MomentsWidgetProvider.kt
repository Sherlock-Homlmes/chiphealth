package vn.chiphealth.app.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import vn.chiphealth.app.R
import java.io.File

/**
 * Home-screen widget showing the newest unseen moment from a friend.
 *
 * Data contract — written from Dart by `MomentsWidgetBridge`
 * (lib/features/moments/data/moments_widget_bridge.dart) through
 * `HomeWidget.saveWidgetData`, and mirroring `GET /v1/moments/widget`:
 *
 *   moment_image_path : String?  absolute path of the cached JPEG
 *   moment_caption    : String?  caption text
 *   moment_author     : String?  friend display name
 *   moment_id         : String?  moment id, used for the deep link
 *   moment_count      : Int      how many unseen moments in total
 *
 * home_widget exposes those under its own SharedPreferences instance, handed to
 * us as `widgetData`.
 */
class MomentsWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.moments_widget).apply {
                val caption = widgetData.getString("moment_caption", null)
                val author = widgetData.getString("moment_author", null)
                val imagePath = widgetData.getString("moment_image_path", null)
                val momentId = widgetData.getString("moment_id", null)

                setTextViewText(
                    R.id.moment_caption,
                    caption ?: context.getString(R.string.widget_empty),
                )
                setTextViewText(R.id.moment_author, author ?: "CHIPHEALTH")

                val bitmap = imagePath
                    ?.let { File(it) }
                    ?.takeIf { it.exists() }
                    ?.let { BitmapFactory.decodeFile(it.absolutePath) }
                if (bitmap != null) {
                    setImageViewBitmap(R.id.moment_image, bitmap)
                } else {
                    setImageViewResource(R.id.moment_image, R.drawable.widget_frame)
                }

                // Tapping the widget deep-links into /moments (optionally a single moment).
                val uri = if (momentId != null) {
                    android.net.Uri.parse("chiphealth://moments/$momentId")
                } else {
                    android.net.Uri.parse("chiphealth://moments")
                }
                val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    vn.chiphealth.app.MainActivity::class.java,
                    uri,
                )
                setOnClickPendingIntent(R.id.moments_widget_root, pendingIntent)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
