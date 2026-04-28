import type { Core } from '@strapi/strapi';

let firebaseAdmin: any = null;

function getFirebaseAdmin() {
  if (firebaseAdmin) return firebaseAdmin;
  try {
    const admin = require('firebase-admin');
    if (!admin.apps.length) {
      admin.initializeApp({
        credential: admin.credential.cert(
          require('../../firebase-service-account.json')
        ),
      });
      console.log('[FCM] Firebase Admin initialisé ✓');
    }
    firebaseAdmin = admin;
  } catch (e: any) {
    console.warn('[FCM] firebase-admin non disponible:', e.message);
  }
  return firebaseAdmin;
}

export default ({ env }: Core.Config.Shared.ConfigParams) => ({
  host: env('HOST', '0.0.0.0'),
  port: env.int('PORT', 1337),
  app: {
    keys: env.array('APP_KEYS'),
  },
  cron: {
    enabled: true,
    tasks: {
      checkScheduledNotifications: {
        task: async ({ strapi }: { strapi: any }) => {
          const now = new Date();
          console.log('[Cron] tick –', now.toISOString());
          try {
            const tasks = (await strapi.entityService.findMany(
              'api::task.task',
              { filters: { scheduledNotification: { $notNull: true } } }
            )) as any[];

            for (const task of tasks) {
              if (!task.scheduledNotification) continue;

              const scheduledDate = new Date(task.scheduledNotification);
              const diffMinutes =
                (now.getTime() - scheduledDate.getTime()) / 60000;

              // Déclenche seulement si la date est passée depuis moins de 2 min
              if (diffMinutes < 0 || diffMinutes > 2) continue;

              console.log(`[Cron] Rappel : "${task.title}" (${task.scheduledNotification})`);

              if (task.fcmToken) {
                const admin = getFirebaseAdmin();
                if (admin) {
                  try {
                    await admin.messaging().send({
                      token: task.fcmToken,
                      notification: {
                        title: 'Rappel de tâche',
                        body: task.title,
                      },
                      data: {
                        taskId: String(task.id),
                        type: 'scheduled_reminder',
                      },
                      android: {
                        priority: 'high',
                        notification: {
                          sound: 'default',
                          channelId: 'task_reminders',
                        },
                      },
                      apns: {
                        payload: { aps: { sound: 'default', badge: 1 } },
                      },
                    });
                    console.log(`[Cron] FCM envoyé pour "${task.title}"`);
                  } catch (err: any) {
                    console.error(`[Cron] Erreur FCM: ${err.message}`);
                  }
                }
              } else {
                console.log(`[Cron] Pas de token FCM pour "${task.title}"`);
              }

              // Efface scheduledNotification pour ne pas retrigger
              await strapi.entityService.update('api::task.task', task.id, {
                data: { scheduledNotification: null },
              });
            }
          } catch (err: any) {
            console.error('[Cron] Erreur générale:', err.message);
          }
        },
        options: {
          rule: '* * * * *', // chaque minute
        },
      },
    },
  },
});
