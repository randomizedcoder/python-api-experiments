from django.urls import path

from dfapi.views import df_view

urlpatterns = [
    # Matches the nginx `location ^~ /api/` upstream route.
    path("api/df/", df_view, name="df"),
]
