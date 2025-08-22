use ferris_says::say;
use std::io::{stdout, BufWriter};

fn main() {
    let out = "Hello World!";
    let width = 100;

    let mut writer = BufWriter::new(stdout());
    say(out, width, &mut writer).unwrap();
}