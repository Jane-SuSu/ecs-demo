from flask import Flask, request, jsonify
import requests
import os

app = Flask(__name__)

WORLD_SERVICE_URL = os.environ.get("WORLD_SERVICE_URL")

@app.route('/')
def index():
    return "Welcome to Hello Service"

@app.route('/hello')
def hello():
    return "hello"

@app.route('/test')
def test():
    try:
        response = requests.get(f"{WORLD_SERVICE_URL}/world")
        world_response = response.text
        return f"hello {world_response}"
    except requests.RequestException as e:
        return f"Error calling world service: {str(e)}", 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
