# python-api-experiments
python-api-experiments

There is a Python/Django application that is not setting cache control headers, but I want to cache the responses with an nginx cache.

The example python/django app should have a simple REST API that will shell out to "df", and then return the df output as JSON.  Let's include a constant that will also make the python sleep for X milliseconds before returning the JSON response.  X should default to 1ms.
