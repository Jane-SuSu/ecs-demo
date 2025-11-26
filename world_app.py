from flask import Flask, request, jsonify
import requests
import os

app = Flask(__name__)

HELLO_SERVICE_URL = os.environ.get("HELLO_SERVICE_URL")

@app.route('/')
def index():
    return "Welcome to World Service"

@app.route('/world')
def world():
    return "world"

@app.route('/test')
def test():
    try:
        response = requests.get(HELLO_SERVICE_URL + "/hello")
        hello_response = response.text
        return f"world {hello_response}"
    except requests.RequestException as e:
        return f"Error calling hello service: {str(e)}", 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001, debug=True)
